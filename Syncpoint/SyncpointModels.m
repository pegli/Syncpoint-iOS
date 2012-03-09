//
//  SyncpointModels.m
//  Syncpoint
//
//  Created by Jens Alfke on 3/7/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "SyncpointModels.h"
#import <CouchCocoa/CouchModelFactory.h>
#import "TDMisc.h"
#import "CollectionUtils.h"


@interface CouchModel (Internal)
- (CouchModel*) getModelProperty: (NSString*)property;
- (void) setModel: (CouchModel*)model forProperty: (NSString*)property;
@end


static NSString* randomString(void) {
    uint8_t randomBytes[16];    // 128 bits of entropy
    SecRandomCopyBytes(kSecRandomDefault, sizeof(randomBytes), randomBytes);
    return TDHexString(randomBytes, sizeof(randomBytes), true);
}


//TODO: This would be useful as a method in CouchModelFactory or CouchDatabase...
static NSEnumerator* modelsOfType(CouchDatabase* database, NSString* type) {
    NSEnumerator* e = [[database getAllDocuments] rows];
    return [e my_map: ^(CouchQueryRow* row) {
        if ([type isEqual: [row.documentProperties objectForKey: @"type"]])
            return [CouchModel modelForDocument: row.document];
        else
            return nil;
    }];
}




@implementation SyncpointSessionItem

@dynamic state;

- (bool) isActive {
    return [self.state isEqual: @"active"];
}

// FIX: This name-mapping should be moved into CouchModel itself somehow.
- (CouchModel*) getModelProperty: (NSString*)property {
    return [super getModelProperty: [property stringByAppendingString: @"_id"]];
}

- (void) setModel: (CouchModel*)model forProperty: (NSString*)property {
    [super setModel: model forProperty: [property stringByAppendingString: @"_id"]];
}

+ (Class) classOfProperty: (NSString*)property {
    if ([property hasSuffix: @"_id"])
        property = [property substringToIndex: property.length-3];
    return [super classOfProperty: property];
}

@end




@implementation SyncpointSession

@dynamic user_id, oauth_creds;


+ (void) initialize {
    if (self == [SyncpointSession class]) {
        CouchModelFactory* factory = [CouchModelFactory sharedInstance]; //TEMP: Should be per-database
        [factory registerClass: @"SyncpointChannel" forDocumentType: @"channel"];
        [factory registerClass: @"SyncpointSubscription" forDocumentType: @"subscription"];
        [factory registerClass: @"SyncpointInstallation" forDocumentType: @"installation"];
    }
}


+ (SyncpointSession*) sessionInDatabase: (CouchDatabase *)database {
    NSString* sessID = [[NSUserDefaults standardUserDefaults] objectForKey:@"Syncpoint_SessionDocID"];
    if (!sessID)
        return nil;
    CouchDocument* doc = [database documentWithID: sessID];
    if (!doc)
        return nil;
    if (!doc.properties) {
        // Oops -- the session ID in user-defaults is out of date, so clear it
        [[NSUserDefaults standardUserDefaults] removeObjectForKey: @"Syncpoint_SessionDocID"];
        return nil;
    }
    return [self modelForDocument: doc];
}


+ (SyncpointSession*) makeSessionInDatabase: (CouchDatabase*)database
                                   withType: (NSString*)type
                                  tokenType: (NSString*)tokenType
                                      token: (NSString*)token
{
    SyncpointSession* session = [[self alloc] initWithNewDocumentInDatabase: database];
    [session setValue: type ofProperty: @"type"];
    [session setValue: token ofProperty: tokenType];
    session.state = @"new";
    NSDictionary* oauth_creds = $dict({@"consumer_key", randomString()},
                                      {@"consumer_secret", randomString()},
                                      {@"token_secret", randomString()},
                                      {@"token", randomString()});
    session.oauth_creds = oauth_creds;
    
    RESTOperation* op = [session save];
    if (![op wait]) {
        Warn(@"SyncpointSession: Couldn't save new session: %@", op.error);
        return nil;
    }
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject: session.document.documentID forKey: @"Syncpoint_SessionDocID"];
    [defaults synchronize];
    return session;
}


- (NSString*) controlDatabaseName {
    return [[self getValueOfProperty: @"session"] objectForKey: @"control_database"];
}


- (SyncpointChannel*) makeChannelWithName: (NSString*)name {
    SyncpointChannel* channel = [[SyncpointChannel alloc] initWithNewDocumentInDatabase: self.database];
    [channel setValue: @"channel" ofProperty: @"type"];
    [channel setValue: self.user_id forKey: @"owner_id"];
    channel.state = @"new";
    channel.name = name;
    return channel;
}


- (SyncpointChannel*) channelWithName: (NSString*)name {
    for (SyncpointChannel* channel in modelsOfType(self.database, @"channel"))
        if ([channel.name isEqualToString: name])
            return channel;
    return nil;
}


- (SyncpointInstallation*) installChannelNamed: (NSString*)name
                                    toDatabase: (CouchDatabase*)localDatabase
{
    Assert(self.isActive);
    
    SyncpointChannel* channel = [self channelWithName: name];
    SyncpointSubscription* subscription = nil;
    SyncpointInstallation* installation = nil;
    if (channel) {
        subscription = channel.subscription;
        installation = channel.installation;
    } else {
        channel = [self makeChannelWithName: name];
        if (!channel)
            return nil;
    }
    
    if (!subscription) {
        if (installation)
            Warn(@"already have an install doc %@ with no subscription for channel %@",
                 installation, channel);
        subscription = [channel makeSubscription];
        if (!subscription)
            return nil;
    }
    
    if (!installation)
        installation = [subscription makeInstallationWithLocalDatabase: localDatabase];
    return installation;
}


- (NSEnumerator*) readyChannels {
    return [modelsOfType(self.database, @"channel") my_map: ^(SyncpointChannel* channel) {
        return channel.isReady ? channel : nil;
    }];
}


- (NSEnumerator*) activeSubscriptions {
    return [modelsOfType(self.database, @"subscripton") my_map: ^(SyncpointSubscription* sub) {
        return sub.isActive ? sub : nil;
    }];
}


- (NSSet*) installedSubscriptions {
    NSMutableSet* subscriptions = [NSMutableSet set];
    for (SyncpointInstallation* inst in modelsOfType(self.database, @"installation"))
        [subscriptions addObject: inst.subscription];
    return subscriptions;
}


- (NSEnumerator*) allInstallations {
    return [modelsOfType(self.database, @"installation") my_map: ^(SyncpointInstallation* inst) {
        return ([inst.state isEqual: @"created"] && inst.session == self) ? inst : nil;
    }];
}


@end




@implementation SyncpointChannel

@dynamic name, cloud_database;

- (bool) isDefault {
    return [[self getValueOfProperty: @"default"] isEqual: $true];
}

- (bool) isReady {
    return [self.state isEqual: @"ready"];
}

- (SyncpointSubscription*) subscription {
    for (SyncpointSubscription* sub in modelsOfType(self.database, @"subscription"))
        if (sub.channel == self)
            return sub;
    return nil;
}

- (SyncpointInstallation*) installation {
    for (SyncpointInstallation* inst in modelsOfType(self.database, @"installation"))
        if (inst.channel == self)
            return inst;
    return nil;
}

- (SyncpointSubscription*) makeSubscription {
    SyncpointSubscription* sub = [[SyncpointSubscription alloc] initWithNewDocumentInDatabase: self.database];
    [sub setValue: @"subscription" ofProperty: @"type"];
    sub.state = @"active";
    [sub setValue: [self getValueOfProperty: @"owner_id"] forKey: @"owner_id"];
    sub.channel = self;
    return sub;
}

@end




@implementation SyncpointSubscription

@dynamic channel;

- (SyncpointInstallation*) makeInstallationWithLocalDatabase: (CouchDatabase*)localDB {
    NSString* name;
    if (localDB)
        name = localDB.relativePath;
    else { 
        name = [@"channel-" stringByAppendingString: randomString()];
        localDB = [self.database.server databaseNamed: name];
    }
    
    if (![localDB ensureCreated: nil]) {
        Warn(@"SyncpointSubscription could not create channel db %@", name);
        return nil;
    }

    SyncpointInstallation* inst = [[SyncpointInstallation alloc] initWithNewDocumentInDatabase: self.database];
    [inst setValue: @"installation" ofProperty: @"type"];
    inst.state = @"created";
    inst.session = [SyncpointSession sessionInDatabase: self.database];
    [inst setValue: [self getValueOfProperty: @"owner_id"] forKey: @"owner_id"];
    inst.channel = self.channel;
    inst.subscription = self;
    [inst setValue: name forKey: @"local_db_name"];
    return inst;
}

@end




@implementation SyncpointInstallation

@dynamic subscription, channel, session;

- (CouchDatabase*) localDatabase {
    NSString* name = $castIf(NSString, [self getValueOfProperty: @"local_db_name"]);
    return name ? [self.database.server databaseNamed: name] : nil;
}

@end
