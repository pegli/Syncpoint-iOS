//
//  SyncpointModels.m
//  Syncpoint
//
//  Created by Jens Alfke on 3/7/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "SyncpointModels.h"
#import "SyncpointInternal.h"
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




@implementation SyncpointModel

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

@dynamic user_id, oauth_creds, control_database;


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
                                      error: (NSError**)outError
{
    LogTo(Syncpoint, @"Creating session %@ in %@", type, database);
    SyncpointSession* session = [[self alloc] initWithNewDocumentInDatabase: database];
    [session setValue: type ofProperty: @"type"];
    [session setValue: token ofProperty: tokenType];
    session.state = @"new";
    NSDictionary* oauth_creds = $dict({@"consumer_key", randomString()},
                                      {@"consumer_secret", randomString()},
                                      {@"token_secret", randomString()},
                                      {@"token", randomString()});
    session.oauth_creds = oauth_creds;
    
    if (![[session save] wait: outError]) {
        Warn(@"SyncpointSession: Couldn't save new session");
        return nil;
    }
    
    NSString* sessionID = session.document.documentID;
    LogTo(Syncpoint, @"...session ID = %@", sessionID);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject: sessionID forKey: @"Syncpoint_SessionDocID"];
    [defaults synchronize];
    return session;
}


- (id) initWithDocument: (CouchDocument*)document {
    self = [super initWithDocument: document];
    if (self) {
        // Register the other model classes with the database's model factory:
        CouchModelFactory* factory = self.database.modelFactory;
        [factory registerClass: @"SyncpointChannel" forDocumentType: @"channel"];
        [factory registerClass: @"SyncpointSubscription" forDocumentType: @"subscription"];
        [factory registerClass: @"SyncpointInstallation" forDocumentType: @"installation"];
    }
    return self;
}


- (SyncpointChannel*) makeChannelWithName: (NSString*)name
                                    error: (NSError**)outError
{
    LogTo(Syncpoint, @"Create channel named '%@'", name);
    SyncpointChannel* channel = [[SyncpointChannel alloc] initWithNewDocumentInDatabase: self.database];
    [channel setValue: @"channel" ofProperty: @"type"];
    [channel setValue: self.user_id ofProperty: @"owner_id"];
    channel.state = @"new";
    channel.name = name;
    return [[channel save] wait: outError] ? channel : nil;
}


- (SyncpointChannel*) channelWithName: (NSString*)name {
    // TODO: Make this into a view query
    for (SyncpointChannel* channel in modelsOfType(self.database, @"channel"))
        if ([channel.name isEqualToString: name])
            return channel;
    return nil;
}


- (SyncpointInstallation*) installChannelNamed: (NSString*)channelName
                                    toDatabase: (CouchDatabase*)localDatabase
                                         error: (NSError**)outError
{
    Assert(self.isActive);
    SyncpointChannel* channel = [self channelWithName: channelName];
    if (!channel)
        channel = [self makeChannelWithName: channelName error: outError];
    return [channel makeInstallationWithLocalDatabase: localDatabase error: outError];
}


- (NSEnumerator*) readyChannels {
    // TODO: Make this into a view query
    return [modelsOfType(self.database, @"channel") my_map: ^(SyncpointChannel* channel) {
        return channel.isReady ? channel : nil;
    }];
}


- (NSEnumerator*) activeSubscriptions {
    // TODO: Make this into a view query
    return [modelsOfType(self.database, @"subscripton") my_map: ^(SyncpointSubscription* sub) {
        return sub.isActive ? sub : nil;
    }];
}


- (NSSet*) installedSubscriptions {
    NSMutableSet* subscriptions = [NSMutableSet set];
    for (SyncpointInstallation* inst in self.allInstallations)
        [subscriptions addObject: inst.subscription];
    return subscriptions;
}


- (NSEnumerator*) allInstallations {
    // TODO: Make this into a view query
    return [modelsOfType(self.database, @"installation") my_map: ^(SyncpointInstallation* inst) {
        return ([inst.state isEqual: @"created"] && inst.session == self) ? inst : nil;
    }];
}


@end




@implementation SyncpointChannel

@dynamic name, owner_id, cloud_database;

- (bool) isReady {
    return [self.state isEqual: @"ready"];
}


- (SyncpointSubscription*) subscription {
    // TODO: Make this into a view query
    for (SyncpointSubscription* sub in modelsOfType(self.database, @"subscription"))
        if (sub.channel == self)
            return sub;
    return nil;
}


- (SyncpointInstallation*) installation {
    // TODO: Make this into a view query
    for (SyncpointInstallation* inst in modelsOfType(self.database, @"installation"))
        if (inst.channel == self && inst.isLocal)
            return inst;
    return nil;
}


- (SyncpointInstallation*) makeInstallationWithLocalDatabase: (CouchDatabase*)localDatabase
                                                       error: (NSError**)outError

{
    SyncpointSubscription* subscription = self.subscription;
    SyncpointInstallation* installation = self.installation;
    if (!subscription) {
        if (installation)
            Warn(@"already have an install doc %@ with no subscription for channel %@",
                 installation, self);
        subscription = [self subscribe: outError];
        if (!subscription)
            return nil;
    }
    
    if (!installation)
        installation = [subscription makeInstallationWithLocalDatabase: localDatabase
                                                                 error: outError];
    return installation;
}


- (SyncpointSubscription*) subscribe: (NSError**)outError {
    LogTo(Syncpoint, @"Subscribing to %@", self);
    SyncpointSubscription* sub = [[SyncpointSubscription alloc] initWithNewDocumentInDatabase: self.database];
    [sub setValue: @"subscription" ofProperty: @"type"];
    sub.state = @"active";
    [sub setValue: [self getValueOfProperty: @"owner_id"] ofProperty: @"owner_id"];
    sub.channel = self;
    return [[sub save] wait: outError] ? sub : nil;
}

- (void) unsubscribe {
    // TODO
}

@end




@implementation SyncpointSubscription

@dynamic channel;

- (SyncpointInstallation*) installation {
    return self.channel.installation;
}

- (SyncpointInstallation*) makeInstallationWithLocalDatabase: (CouchDatabase*)localDB
                                                       error: (NSError**)outError
{
    NSString* name;
    if (localDB)
        name = localDB.relativePath;
    else { 
        name = [@"channel-" stringByAppendingString: randomString()];
        localDB = [self.database.server databaseNamed: name];
    }
    
    LogTo(Syncpoint, @"Installing %@ to %@", self, localDB);
    if (![localDB ensureCreated: nil]) {
        Warn(@"SyncpointSubscription could not create channel db %@", name);
        return nil;
    }

    SyncpointInstallation* inst = [[SyncpointInstallation alloc] initWithNewDocumentInDatabase: self.database];
    [inst setValue: @"installation" ofProperty: @"type"];
    inst.state = @"created";
    inst.session = [SyncpointSession sessionInDatabase: self.database];
    [inst setValue: [self getValueOfProperty: @"owner_id"] ofProperty: @"owner_id"];
    inst.channel = self.channel;
    inst.subscription = self;
    [inst setValue: name ofProperty: @"local_db_name"];
    return [[inst save] wait: outError] ? inst : nil;
}

@end




@implementation SyncpointInstallation

@dynamic subscription, channel, session;

- (CouchDatabase*) localDatabase {
    if (!self.isLocal)
        return nil;
    NSString* name = $castIf(NSString, [self getValueOfProperty: @"local_db_name"]);
    return name ? [self.database.server databaseNamed: name] : nil;
}

- (bool) isLocal {
    SyncpointSession* session = [SyncpointSession sessionInDatabase: self.database];
    return [session.document.documentID isEqual: [self getValueOfProperty: @"session_id"]];
}

@end
