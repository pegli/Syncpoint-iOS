//
//  Syncpoint.m
//  Syncpoint
//
//  Created by Jens Alfke on 2/23/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "Syncpoint.h"
#import "Facebook.h"
#import <CouchCocoa/CouchCocoa.h>
#import "TDMisc.h"


#define kSessionDatabaseName @"sessions"


@interface Syncpoint () <FBSessionDelegate, FBRequestDelegate>
@property (readwrite) NSError* error;
@property NSString* syncpointSessionId;
- (void) connectToControlDb;
- (void) syncSessionDocument;
- (BOOL) sessionIsActive;
- (void) sessionDatabaseChanged;
- (void) getUpToDateWithSubscriptions;
@end


@implementation Syncpoint


@synthesize error=_error, facebookAppID=_facebookAppID, appDatabaseName=_appDatabaseName;


- (id) initWithLocalServer: (CouchServer*)localServer remoteServer: (NSURL*)remoteServerURL {
    CAssert(localServer);
    CAssert(remoteServerURL);
    self = [super init];
    if (self) {
        _server = localServer;
        _remote = remoteServerURL;
    }
    return self;
}

- (id) initWithRemoteServer:(NSURL *)remoteServerURL {
    return [self initWithLocalServer: [CouchTouchDBServer sharedInstance] 
                        remoteServer: remoteServerURL];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver: self];
}


- (BOOL) start {
    Assert(!_sessionDatabase, @"Already started");
    _sessionDatabase = [_server databaseNamed: kSessionDatabaseName];
    
    // Create the session database on the first run of the app.
    NSError* error;
    if (![_sessionDatabase ensureCreated: &error]) {
        self.error = error;
        return NO;
    }
    _sessionDatabase.tracksChanges = YES;

    NSString* sessionID = self.syncpointSessionId;
    if (sessionID) {
        LogTo(SyncPoint, @"has session");
        _sessionDoc = [_sessionDatabase documentWithID: sessionID];
        if ([self sessionIsActive]) {
            //        setup sync with the user control database
            LogTo(SyncPoint, @"go directly to user control");
            _sessionSynced = YES;
            [self connectToControlDb];
            [[NSNotificationCenter defaultCenter] addObserver: self 
                                                     selector: @selector(sessionDatabaseChanged)
                                                         name: kCouchDatabaseChangeNotification 
                                                       object: _sessionDatabase];
        } else {
            LogTo(SyncPoint, @"session not active");
            [self syncSessionDocument];
        }
    } else {
        LogTo(SyncPoint, @"no session");
        
        // Setup Facebook:
        _facebook = [[Facebook alloc] initWithAppId: _facebookAppID andDelegate: self];
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        NSString* accessToken = [defaults objectForKey:@"Syncpoint_FBAccessToken"];
        NSDate* expirationDate = [defaults objectForKey:@"Syncpoint_FBExpirationDate"];
        if (accessToken && expirationDate) {
            _facebook.accessToken = accessToken;
            _facebook.expirationDate = expirationDate;
        }
    }

    return YES;
}


- (void) initiatePairing {
    if (![_facebook isSessionValid])
        [_facebook authorize:nil];
}

- (void) removePairing {
    //    todo: delete the session document
    //    [sessionDocument delete]
    [_facebook logout];
}



- (id)syncpointSessionId {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"Syncpoint_SessionDocId"];
}

- (void) setSyncpointSessionId: (NSString*)sessionID {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject: sessionID forKey: @"Syncpoint_SessionDocId"];
    [defaults synchronize];
}


-(BOOL)sessionIsActive {
    Assert(_sessionDoc);
    LogTo(SyncPoint, @"sessionIsActive? %@",[_sessionDoc.properties objectForKey:@"state"]);
    return [[_sessionDoc.properties objectForKey:@"state"] isEqualToString:@"active"];
}


-(void) syncSessionDocument {
    NSURL* sessionSyncDbURL = [NSURL URLWithString: kSessionDatabaseName relativeToURL: _remote];
    [[_sessionDatabase pushToDatabaseAtURL: sessionSyncDbURL] start];
    LogTo(SyncPoint, @"syncSessionDocument pushing");
    
    _sessionPull = [_sessionDatabase pullFromDatabaseAtURL: sessionSyncDbURL];
    //    todo add a by docid read rule so I only see my document
    
    NSString *docIdsString = [NSString stringWithFormat:@"[\"%@\"]",
                              _sessionDoc.documentID];
    _sessionPull.filter = @"_doc_ids";
    _sessionPull.filterParams = $dict({@"doc_ids", docIdsString});
    _sessionPull.continuous = YES;
    [_sessionPull start];
    LogTo(SyncPoint, @"syncSessionDocument pulled");
    
    //    ok now we should listen to changes on the session db and stop replication 
    //    when we get our doc back in a finalized state
    _sessionSynced = NO;
    LogTo(SyncPoint, @"observing session db");
    [[NSNotificationCenter defaultCenter] addObserver: self 
                                             selector: @selector(sessionDatabaseChanged)
                                                 name: kCouchDatabaseChangeNotification 
                                               object: _sessionDatabase];
}


-(CouchDocument*) makeInstallationForSubscription: (CouchDocument*)subscription
                                withDatabaseNamed:(NSString*) name
{
    CouchDocument *installation = [_sessionDatabase untitledDocument];
    if (name == nil) {
        name = [@"channel-" stringByAppendingString:[self randomString]];
    }
    CouchDatabase *channelDb = [_server databaseNamed: name];
    LogTo(SyncPoint, @"create channel db %@",name);
    
    // Create the session database on the first run of the app.
    NSError* error;
    if (![channelDb ensureCreated: &error]) {
        LogTo(SyncPoint, @"could not create channel db %@",name);
        exit(-1);
    }
    [[[installation putProperties:[NSDictionary dictionaryWithObjectsAndKeys:
                                   name, @"local_db_name", 
                                   [subscription.properties objectForKey:@"owner_id"], @"owner_id", 
                                   [subscription.properties objectForKey:@"channel_id"], @"channel_id", 
                                   _sessionDoc.documentID, @"session_id", 
                                   subscription.documentID, @"subscription_id", 
                                   @"installation",@"type",
                                   @"created",@"state",
                                   nil]] start] wait];
    return installation;
}


-(CouchDocument*) makeSubscriptionForChannel: (CouchDocument*)channel
                                  andOwnerId: (NSString*) ownerId
{
    CouchDocument *subscription = [_sessionDatabase untitledDocument];
    [[[subscription putProperties:[NSDictionary dictionaryWithObjectsAndKeys:
                                   ownerId, @"owner_id", 
                                   channel.documentID, @"channel_id", 
                                   @"subscription",@"type",
                                   @"active",@"state",
                                   nil]] start] wait];
    return subscription;
}


-(void) maybeInitializeDefaultChannel {
    CouchQueryEnumerator *rows = [[_sessionDatabase getAllDocuments] rows];
    CouchQueryRow *row;
    
    CouchDocument *channel = nil; // global, owned by user and private by default
    CouchDocument *subscription = nil; // user
    CouchDocument *installation = nil; // per session
    //    if we have a channel owned by the user, and it is flagged default == true,
    //    then we don't need to make a channel doc or a subscription,
    //    but we do need to make an installation doc that references the subscription.
    
    //    if we don't have a default channel owned by the user, 
    //    then we need to create it, and a subcription to it (by the owner).
    //    also we create an installation doc linking the kDatabaseName (pre-pairing) database
    //    with the channel & subscription.
    
    //    note: need a channel doc and a subscription doc only makes sense when you need to 
    //    allow for channels that are shared by multiple users.
    NSString *myUserId= [[_sessionDoc.properties objectForKey:@"session"] objectForKey:@"user_id"];
    while ((row = [rows nextRow])) { 
        if ([[row.documentProperties objectForKey:@"type"] isEqualToString:@"channel"] && [[row.documentProperties objectForKey:@"owner_id"] isEqualToString:myUserId] && ([row.documentProperties objectForKey:@"default"] == [NSNumber numberWithBool:YES])) {
            channel = row.document;
        }
    }
    if (channel) {
        //    TODO use a query
        CouchQueryEnumerator *rows2 = [[_sessionDatabase getAllDocuments] rows];
        while ((row = [rows2 nextRow])) {
            if ([[row.documentProperties objectForKey:@"local_db_name"] isEqualToString:_appDatabaseName] && [[row.documentProperties objectForKey:@"session_id"] isEqualToString:_sessionDoc.documentID] && [[row.documentProperties objectForKey:@"channel_id"] isEqualToString:channel.documentID]) {
                installation =  row.document;
            } else if ([[row.documentProperties objectForKey:@"type"] isEqualToString:@"subscription"] && [[row.documentProperties objectForKey:@"owner_id"] isEqualToString:myUserId] && [[row.documentProperties objectForKey:@"channel_id"] isEqualToString:channel.documentID]) {
                subscription = row.document;
            }
        }
        LogTo(SyncPoint, @"channel %@", channel.description);
        LogTo(SyncPoint, @"subscription %@", subscription.description);
        LogTo(SyncPoint, @"installation %@", installation.description);
        if (subscription) {
            if (installation) {
                //                we are set, sync will trigger based on the installation
            } else {
                //                we have a subscription and a channel (created on another device)
                //                but we do not have a local installation, so let's make one
                installation = [self makeInstallationForSubscription: subscription
                                                   withDatabaseNamed:_appDatabaseName];
            }
        } else {
            //            channel but no subscription, maybe we crashed earlier or had a partial sync
            subscription = [self makeSubscriptionForChannel: channel andOwnerId:myUserId];
            if (installation) {
                //                we already have an install doc for the local device, this should never happen
            } else {
                installation = [self makeInstallationForSubscription: subscription
                                                   withDatabaseNamed:_appDatabaseName];
            }
        }
    } else {
        //     make a channel, subscription, and installation
        channel = [_sessionDatabase untitledDocument];
        [[[channel putProperties:[NSDictionary dictionaryWithObjectsAndKeys:
                                  @"Default List", @"name",
                                  [NSNumber numberWithBool:YES], @"default",
                                  @"channel",@"type",
                                  myUserId, @"owner_id", 
                                  @"new",@"state",
                                  nil]] start] wait];
        subscription = [self makeSubscriptionForChannel: channel andOwnerId:myUserId];
        installation = [self makeInstallationForSubscription: subscription
                                           withDatabaseNamed:_appDatabaseName];
    }
}


- (NSURL*) controlDBURL {
    NSString* controlDBName = [[_sessionDoc.properties objectForKey:@"session"]
                                        objectForKey:@"control_database"];
    return [NSURL URLWithString: controlDBName relativeToURL: _remote];
}


-(void)connectToControlDb {
    NSAssert([self sessionIsActive], @"session must be active");
    NSURL* controlDBURL = self.controlDBURL;
    LogTo(SyncPoint, @"connecting to control database %@",controlDBURL);
    
    _sessionPull = [_sessionDatabase pullFromDatabaseAtURL: controlDBURL];
    [_sessionPull start];
    LogTo(SyncPoint, @" _sessionPull running %d",_sessionPull.running);
    [_sessionPull addObserver: self forKeyPath: @"running" options: 0 context: NULL];
    
    _sessionPush = [_sessionDatabase pushToDatabaseAtURL: controlDBURL];
    _sessionPush.continuous = YES;
    [_sessionPush start];
}


- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object 
                         change:(NSDictionary *)change context:(void *)context
{
    LogTo(SyncPoint, @" observeValueForKeyPath _sessionPull running %d",_sessionPull.running);
    if (object == _sessionPull && !_sessionPull.running) {
        NSURL* controlDBURL = self.controlDBURL;
        [_sessionPull removeObserver: self forKeyPath: @"running"];
        [_sessionPull stop];
        LogTo(SyncPoint, @"finished first pull, checking channels status");
        [self maybeInitializeDefaultChannel];
        [self getUpToDateWithSubscriptions];
        _sessionPull = [_sessionDatabase pullFromDatabaseAtURL: controlDBURL];
        _sessionPull.continuous = YES;
        [_sessionPull start];
    }
}


-(NSMutableArray*) activeSubscriptionsWithoutInstallations {
    NSMutableArray *subs = [NSMutableArray array];
    NSMutableArray *installed_sub_ids = [NSMutableArray array];
    NSMutableArray *results = [NSMutableArray array];
    NSString *myUserId= [[_sessionDoc.properties objectForKey:@"session"] objectForKey:@"user_id"];
    CouchQueryEnumerator *rows = [[_sessionDatabase getAllDocuments] rows];
    CouchQueryRow *row;
    while ((row = [rows nextRow])) {
        if ([[row.documentProperties objectForKey:@"type"] isEqualToString:@"subscription"] && [[row.documentProperties objectForKey:@"owner_id"] isEqualToString:myUserId] && [[row.documentProperties objectForKey:@"state"] isEqualToString:@"active"]) {
            [subs addObject:row.document];
        } else if ([[row.documentProperties objectForKey:@"type"] isEqualToString:@"installation"] && [[row.documentProperties objectForKey:@"session_id"] isEqualToString:_sessionDoc.documentID]) {
            [installed_sub_ids addObject:[row.documentProperties objectForKey:@"subscription_id"]];
        }
    }
    [subs enumerateObjectsUsingBlock:^(CouchDocument *obj, NSUInteger idx, BOOL *stop) {
        if (NSNotFound == [installed_sub_ids indexOfObjectPassingTest:^(id sid, NSUInteger idx, BOOL *end){
            return [sid isEqualToString:obj.documentID];
        }]) {
            [results addObject:obj];
        }
    }];
    return results;
}


-(NSMutableArray*) createdInstallationsWithReadyChannels {
    NSString *myUserId= [[_sessionDoc.properties objectForKey:@"session"] objectForKey:@"user_id"];
    CouchQueryEnumerator *rows = [[_sessionDatabase getAllDocuments] rows];
    CouchQueryRow *row;
    NSMutableArray *installs = [NSMutableArray array];
    NSMutableArray *results = [NSMutableArray array];
    NSMutableArray *ready_channel_ids = [NSMutableArray array];
    while ((row = [rows nextRow])) {
        if ([[row.documentProperties objectForKey:@"type"] isEqualToString:@"installation"] && [[row.documentProperties objectForKey:@"state"] isEqualToString:@"created"] && [[row.documentProperties objectForKey:@"session_id"] isEqualToString:_sessionDoc.documentID]) {
            [installs addObject:row.document];
        } else if ([[row.documentProperties objectForKey:@"type"] isEqualToString:@"channel"] && [[row.documentProperties objectForKey:@"state"] isEqualToString:@"ready"] && [[row.documentProperties objectForKey:@"owner_id"] isEqualToString:myUserId]) {
            [ready_channel_ids addObject:row.documentID];
        }
    }
    [installs enumerateObjectsUsingBlock:^(CouchDocument *obj, NSUInteger idx, BOOL *stop) {
        if (NSNotFound != [ready_channel_ids indexOfObjectPassingTest:^(id chid, NSUInteger idx, BOOL *end){
            return [chid isEqualToString:[obj.properties objectForKey:@"channel_id"]];
        }]) {
            [results addObject:obj];
        }
    }];
    return results;
}


-(void) getUpToDateWithSubscriptions {
    LogTo(SyncPoint, @"getUpToDateWithSubscriptions");
    for (id needInstall in self.activeSubscriptionsWithoutInstallations)
        [self makeInstallationForSubscription: needInstall withDatabaseNamed:nil];

    for (CouchDocument *obj in [self createdInstallationsWithReadyChannels]) {
        LogTo(SyncPoint, @"setup sync for installation %@", obj);
        //        TODO setup sync with the database listed in "cloud_database" on the channel doc
        //        this means we need the server side to actually make some channels "ready" first
        CouchDocument *channelDoc = [_sessionDatabase documentWithID:[obj.properties objectForKey:@"channel_id"]];
        CouchDatabase *localChannelDb = [_server databaseNamed: [obj.properties objectForKey:@"local_db_name"]];
        NSString* cloudChannelName = [channelDoc.properties objectForKey:@"cloud_database"];
        NSURL *cloudChannelURL = [NSURL URLWithString: cloudChannelName relativeToURL: _remote];
        CouchReplication *pull = [localChannelDb pullFromDatabaseAtURL:cloudChannelURL];
        pull.continuous = YES;
        CouchReplication *push = [localChannelDb pushToDatabaseAtURL:cloudChannelURL];
        push.continuous = YES;
    }
}


-(void)sessionDatabaseChanged {
    LogTo(SyncPoint, @"sessionDatabaseChanged _sessionSynced: %d", _sessionSynced);
    if (!_sessionSynced && self.sessionIsActive) {
        if (_sessionPull && _sessionPush) {
            LogTo(SyncPoint, @"switch to user control db, pull %@ push %@", _sessionPull, _sessionPush);
            [_sessionPull stop];
            LogTo(SyncPoint, @"stopped pull, stopping push");
            [_sessionPush stop];
        }
        _sessionSynced = YES;
        
        [self connectToControlDb];
    } else {
        LogTo(SyncPoint, @"change on local session db");
        //        re run state manager for subscription docs
        [self getUpToDateWithSubscriptions];
    }
}


- (NSString*) randomString {
    uint8_t randomBytes[16];    // 128 bits of entropy
    SecRandomCopyBytes(kSecRandomDefault, sizeof(randomBytes), randomBytes);
    return TDHexString(randomBytes, sizeof(randomBytes), true);
}


- (NSMutableDictionary*) randomOAuthCreds {
    return [NSMutableDictionary dictionaryWithObjectsAndKeys:
            [self randomString], @"consumer_key",
            [self randomString], @"consumer_secret",
            [self randomString], @"token_secret",
            [self randomString], @"token",
            nil];
}


- (void)getSyncpointSessionFromFBAccessToken:(id) accessToken {
    //  it's possible we could log into facebook even though we already have
    //  a Syncpoint session. This guard is to prevent extra requests.
    if (![self syncpointSessionId]) {
        //        save a document that has the facebook access code, to the handshake database.
        //        the document also needs to have the oath credentials we'll use when replicating.
        //        the server will use the access code to find the facebook uid, which we can use to 
        //        look up the syncpoint user, and link these credentials to that user (establishing our session)
        NSMutableDictionary *sessionData = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                            accessToken, @"fb_access_token",
                                            [self randomOAuthCreds], @"oauth_creds",
                                            @"new", @"state",
                                            @"session-fb",@"type",
                                            //      todo this document needs to have our devices SSL cert signature in it
                                            //      so we can enforce that only this device can read this document
                                            nil];
        LogTo(SyncPoint, @"session data %@",[sessionData description]);
        _sessionDoc = [_sessionDatabase untitledDocument];
        RESTOperation *op = [[_sessionDoc putProperties:sessionData] start];
        [op onCompletion:^{
            if (op.error) {
                LogTo(SyncPoint, @"op error %@",op.error);                
            } else {
                LogTo(SyncPoint, @"session doc %@",[_sessionDoc description]);
                self.syncpointSessionId = _sessionDoc.documentID;
                [self syncSessionDocument];
            }
        }];
    }
}


#pragma mark - FACEBOOK GLUE:


- (BOOL) handleOpenURL: (NSURL*)url {
    return [_facebook handleOpenURL:url];
}


- (void)fbDidLogin {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:[_facebook accessToken] forKey:@"Syncpoint_FBAccessToken"];
    [defaults setObject:[_facebook expirationDate] forKey:@"Syncpoint_FBExpirationDate"];
    [defaults synchronize];
    [self getSyncpointSessionFromFBAccessToken: [_facebook accessToken]];
}

/**
 * Called when the user canceled the authorization dialog.
 */
-(void)fbDidNotLogin:(BOOL)cancelled {
    // we don't have anything really to do here
}


- (void)fbDidExtendToken:(NSString*)accessToken
               expiresAt:(NSDate*)expiresAt
{
    // TODO: IMPLEMENT
}

- (void)fbDidLogout {
    // TODO: IMPLEMENT
}

- (void)fbSessionInvalidated {
    // TODO: IMPLEMENT
}


@end
