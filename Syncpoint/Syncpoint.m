//
//  Syncpoint.m
//  Syncpoint
//
//  Created by Jens Alfke on 2/23/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "Syncpoint.h"
#import "SyncpointAuth.h"
#import <CouchCocoa/CouchCocoa.h>
#import "TDMisc.h"


#define kSessionDatabaseName @"sessions"


@interface Syncpoint ()
@property (readwrite) NSError* error;
@property NSString* syncpointSessionId;
@end


@implementation Syncpoint


@synthesize error=_error, appDatabaseName=_appDatabaseName;


- (id) initWithLocalServer: (CouchServer*)localServer
              remoteServer: (NSURL*)remoteServerURL
             authenticator: (SyncpointAuth*)authenticator
{
    CAssert(localServer);
    CAssert(remoteServerURL);
    CAssert(authenticator);
    self = [super init];
    if (self) {
        _server = localServer;
        _remote = remoteServerURL;
        _authenticator = authenticator;
    }
    return self;
}


- (void)dealloc
{
    [self stopObservingSessionPull];
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
        _sessionDoc = [_sessionDatabase documentWithID: sessionID];
        if (self.sessionIsActive) {
            // Setup sync with the user control database
            LogTo(Syncpoint, @"Session is active -- go directly to user control");
            _sessionSynced = YES;
            [self connectToControlDb];
            [self observeSessionDatabase];
        } else {
            LogTo(Syncpoint, @"session not active");
            [self syncSessionDocument];
        }
    } else {
        LogTo(Syncpoint, @"no session");
    }

    return YES;
}


- (void) initiatePairing {
    [_authenticator initiatePairing];
}


- (BOOL) handleOpenURL: (NSURL*)url {
    return [_authenticator handleOpenURL: url];
}


- (id)syncpointSessionId {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"Syncpoint_SessionDocId"];
}

- (void) setSyncpointSessionId: (NSString*)sessionID {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject: sessionID forKey: @"Syncpoint_SessionDocId"];
    [defaults synchronize];
}


- (BOOL)sessionIsActive {
    return _sessionDoc && [[_sessionDoc.properties objectForKey:@"state"] isEqual: @"active"];
}


- (NSString*) myUserID {
    return [[_sessionDoc.properties objectForKey:@"session"] objectForKey:@"user_id"];
}


// Starts an async bidirectional sync of the _sessionDoc in the _sessionDatabase.
- (void) syncSessionDocument {
    NSURL* sessionSyncDbURL = [NSURL URLWithString: kSessionDatabaseName relativeToURL: _remote];
    [[_sessionDatabase pushToDatabaseAtURL: sessionSyncDbURL] start];
    LogTo(Syncpoint, @"syncSessionDocument pushing");
    
    _sessionPull = [_sessionDatabase pullFromDatabaseAtURL: sessionSyncDbURL];
    // TODO: add a by docid read rule so I only see my document
    
    NSString *docIdsString = [NSString stringWithFormat:@"[\"%@\"]",
                              _sessionDoc.documentID];
    _sessionPull.filter = @"_doc_ids";
    _sessionPull.filterParams = $dict({@"doc_ids", docIdsString});
    _sessionPull.continuous = YES;
    [_sessionPull start];
    LogTo(Syncpoint, @"syncSessionDocument pulled");
    
    //    ok now we should listen to changes on the session db and stop replication 
    //    when we get our doc back in a finalized state
    _sessionSynced = NO;
    [self observeSessionDatabase];
}


- (CouchDocument*) makeInstallationForSubscription: (CouchDocument*)subscription
                                 withDatabaseNamed: (NSString*)name
                                             error: (NSError**)outError
{
    if (!name)
        name = [@"channel-" stringByAppendingString:[self randomString]];
    LogTo(Syncpoint, @"create channel db %@",name);
    
    // Create the session database on the first run of the app.
    CouchDatabase *channelDb = [_server databaseNamed: name];
    if (![channelDb ensureCreated: outError]) {
        LogTo(Syncpoint, @"could not create channel db %@",name);
        return nil;
    }
    
    NSDictionary* subscriptionProps = subscription.properties;
    
    CouchDocument *installation = [_sessionDatabase untitledDocument];
    RESTOperation* op = [installation putProperties: $dict(
                           {@"type", @"installation"},
                           {@"state", @"created"},
                           {@"session_id", _sessionDoc.documentID},
                           {@"local_db_name", name},
                           {@"subscription_id", subscription.documentID},
                           {@"owner_id", [subscriptionProps objectForKey: @"owner_id"]},
                           {@"channel_id", [subscriptionProps objectForKey: @"channel_id"]})];
    if (![[op start] wait]) {
        LogTo(Syncpoint, @"could not create installation doc: %@", op.error);
        if (outError)
            *outError = op.error;
        return nil;
    }
    return installation;
}


- (CouchDocument*) makeSubscriptionForChannel: (CouchDocument*)channel
                                   andOwnerId: (NSString*) ownerId
{
    CouchDocument *subscription = [_sessionDatabase untitledDocument];
    RESTOperation* op = [subscription putProperties: $dict(
                           {@"type", @"subscription"},
                           {@"state", @"active"},
                           {@"owner_id", ownerId},
                           {@"channel_id", channel.documentID})];
    if (![[op start] wait]) {
        LogTo(Syncpoint, @"could not create subscription doc: %@", op.error);
        return nil;
    }
    return subscription;
}


- (void) maybeInitializeDefaultChannel {
    //    if we have a channel owned by the user, and it is flagged default == true,
    //    then we don't need to make a channel doc or a subscription,
    //    but we do need to make an installation doc that references the subscription.
    
    //    if we don't have a default channel owned by the user, 
    //    then we need to create it, and a subcription to it (by the owner).
    //    also we create an installation doc linking the kDatabaseName (pre-pairing) database
    //    with the channel & subscription.
    
    //    note: need a channel doc and a subscription doc only makes sense when you need to 
    //    allow for channels that are shared by multiple users.
    CouchDocument *channel = nil; // global, owned by user and private by default
    NSString *myUserId= self.myUserID;
    for (CouchQueryRow* row in [[_sessionDatabase getAllDocuments] rows]) {
        NSDictionary* docProps = row.documentProperties;
        if ([[docProps objectForKey:@"type"] isEqual: @"channel"]
                && [[docProps objectForKey: @"owner_id"] isEqual: myUserId]
                && ([docProps objectForKey: @"default"] == $true)) {
            channel = row.document;
            break;
        }
    }
    
    CouchDocument *subscription = nil; // user
    CouchDocument *installation = nil; // per session
    if (channel) {
        // TODO: use a query
        for (CouchQueryRow* row in [[_sessionDatabase getAllDocuments] rows]) {
            NSDictionary* docProps = row.documentProperties;
            if ([[docProps objectForKey:@"local_db_name"] isEqual: _appDatabaseName]
                    && [[docProps objectForKey:@"session_id"] isEqual: _sessionDoc.documentID]
                    && [[docProps objectForKey:@"channel_id"] isEqual: channel.documentID]) {
                installation =  row.document;
            } else if ([[docProps objectForKey:@"type"] isEqual:@"subscription"]
                       && [[docProps objectForKey:@"owner_id"] isEqual: myUserId] 
                       && [[docProps objectForKey:@"channel_id"] isEqual: channel.documentID]) {
                subscription = row.document;
            }
        }
        LogTo(Syncpoint, @"channel %@", channel.description);
        LogTo(Syncpoint, @"subscription %@", subscription.description);
        LogTo(Syncpoint, @"installation %@", installation.description);
        if (!subscription) {
            // channel but no subscription, maybe we crashed earlier or had a partial sync
            subscription = [self makeSubscriptionForChannel: channel andOwnerId:myUserId];
            if (installation)
                Warn(@"already have an install doc for the local device; this should never happen");
        }
    } else {
        //     make a channel, subscription, and installation
        channel = [_sessionDatabase untitledDocument];
        RESTOperation* op = [channel putProperties: $dict({@"type", @"channel"},
                                                          {@"state", @"new"},
                                                          {@"name", @"Default List"},
                                                          {@"default", $true},
                                                          {@"owner_id", myUserId})];
        if (![[op start] wait]) {
            Warn(@"Syncpoint: Failed to create channel doc: %@", op.error);
            return;
        }
        subscription = [self makeSubscriptionForChannel: channel andOwnerId: myUserId];
    }
    
    if (!installation)
        installation = [self makeInstallationForSubscription: subscription
                                           withDatabaseNamed: _appDatabaseName
                                                       error: nil];
}


- (NSURL*) controlDBURL {
    NSString* controlDBName = [[_sessionDoc.properties objectForKey: @"session"]
                                        objectForKey: @"control_database"];
    return [NSURL URLWithString: controlDBName relativeToURL: _remote];
}


- (void)connectToControlDb {
    Assert(self.sessionIsActive);
    NSURL* controlDBURL = self.controlDBURL;
    LogTo(Syncpoint, @"connecting to control database %@",controlDBURL);
    
    _sessionPull = [_sessionDatabase pullFromDatabaseAtURL: controlDBURL];
    [_sessionPull start];
    LogTo(Syncpoint, @" _sessionPull running %d",_sessionPull.running);
    [_sessionPull addObserver: self forKeyPath: @"running" options: 0 context: NULL];
    _observingSessionPull = YES;
    
    _sessionPush = [_sessionDatabase pushToDatabaseAtURL: controlDBURL];
    _sessionPush.continuous = YES;
    [_sessionPush start];
}


- (void) stopObservingSessionPull {
    if (_observingSessionPull) {
        [_sessionPull removeObserver: self forKeyPath: @"running"];
        _observingSessionPull = NO;
    }
}


- (void) observeValueForKeyPath: (NSString*)keyPath ofObject: (id)object 
                         change: (NSDictionary*)change context: (void*)context
{
    LogTo(Syncpoint, @" observeValueForKeyPath _sessionPull running %d",_sessionPull.running);
    if (object == _sessionPull && !_sessionPull.running) {
        NSURL* controlDBURL = self.controlDBURL;
        [self stopObservingSessionPull];
        [_sessionPull stop];
        _sessionPull = nil;
        LogTo(Syncpoint, @"finished first pull, checking channels status");
        [self maybeInitializeDefaultChannel];
        [self getUpToDateWithSubscriptions];
        _sessionPull = [_sessionDatabase pullFromDatabaseAtURL: controlDBURL];
        _sessionPull.continuous = YES;
        [_sessionPull start];
    }
}


- (NSArray*) activeSubscriptionsWithoutInstallations {
    NSMutableArray *subs = [NSMutableArray array];
    NSMutableArray *installed_sub_ids = [NSMutableArray array];
    NSString *myUserId = self.myUserID;
    for (CouchQueryRow *row in [[_sessionDatabase getAllDocuments] rows]) {
        NSDictionary* docProperties = row.documentProperties;
        if ([[docProperties objectForKey:@"type"] isEqual:@"subscription"]
                && [[docProperties objectForKey:@"owner_id"] isEqual: myUserId]
                && [[docProperties objectForKey:@"state"] isEqual: @"active"]) {
            [subs addObject:row.document];
        } else if ([[docProperties objectForKey:@"type"] isEqual: @"installation"]
                   && [[docProperties objectForKey:@"session_id"] isEqual:_sessionDoc.documentID]) {
            [installed_sub_ids addObject: [docProperties objectForKey: @"subscription_id"]];
        }
    }
    
    return [subs my_filter: ^(CouchDocument* doc) {
        return ![installed_sub_ids containsObject: doc.documentID];
    }];
}


- (NSArray*) createdInstallationsWithReadyChannels {
    NSString *myUserId = self.myUserID;
    NSMutableArray *installs = [NSMutableArray array];
    NSMutableArray *ready_channel_ids = [NSMutableArray array];
    for (CouchQueryRow *row in [[_sessionDatabase getAllDocuments] rows]) {
        NSDictionary* docProperties = row.documentProperties;
        if ([[docProperties objectForKey:@"type"] isEqual:@"installation"]
                && [[docProperties objectForKey:@"state"] isEqual:@"created"]
                && [[docProperties objectForKey:@"session_id"] isEqual:_sessionDoc.documentID]) {
            [installs addObject: row.document];
        } else if ([[docProperties objectForKey:@"type"] isEqual:@"channel"]
                   && [[docProperties objectForKey:@"state"] isEqual:@"ready"]
                   && [[docProperties objectForKey:@"owner_id"] isEqual:myUserId]) {
            [ready_channel_ids addObject: row.documentID];
        }
    }
    
    return [installs my_filter: ^int(CouchDocument* doc) {
        NSString* channelID = [doc.properties objectForKey:@"channel_id"];
        return [ready_channel_ids containsObject: channelID];
    }];
}


- (void) getUpToDateWithSubscriptions {
    LogTo(Syncpoint, @"getUpToDateWithSubscriptions");
    for (CouchDocument* needInstall in self.activeSubscriptionsWithoutInstallations)
        [self makeInstallationForSubscription: needInstall withDatabaseNamed: nil error: nil];

    for (CouchDocument *installation in [self createdInstallationsWithReadyChannels]) {
        LogTo(Syncpoint, @"setup sync for installation %@", installation);
        // TODO: setup sync with the database listed in "cloud_database" on the channel doc
        // This means we need the server side to actually make some channels "ready" first
        CouchDocument *channelDoc = [_sessionDatabase documentWithID:[installation.properties objectForKey:@"channel_id"]];
        CouchDatabase *localChannelDb = [_server databaseNamed: [installation.properties objectForKey:@"local_db_name"]];
        NSString* cloudChannelName = [channelDoc.properties objectForKey:@"cloud_database"];
        NSURL *cloudChannelURL = [NSURL URLWithString: cloudChannelName relativeToURL: _remote];
        CouchReplication *pull = [localChannelDb pullFromDatabaseAtURL:cloudChannelURL];
        pull.continuous = YES;
        CouchReplication *push = [localChannelDb pushToDatabaseAtURL:cloudChannelURL];
        push.continuous = YES;
    }
}


- (void) observeSessionDatabase {
    Assert(_sessionDatabase);
    LogTo(Syncpoint, @"observing session db");
    [[NSNotificationCenter defaultCenter] addObserver: self 
                                             selector: @selector(sessionDatabaseChanged)
                                                 name: kCouchDatabaseChangeNotification 
                                               object: _sessionDatabase];
}

- (void)sessionDatabaseChanged {
    LogTo(Syncpoint, @"sessionDatabaseChanged: _sessionSynced: %d", _sessionSynced);
    if (!_sessionSynced && self.sessionIsActive) {
        if (_sessionPull && _sessionPush) {
            LogTo(Syncpoint, @"switch to user control db, pull %@ push %@", _sessionPull, _sessionPush);
            [_sessionPull stop];
            LogTo(Syncpoint, @"stopped pull, stopping push");
            [_sessionPush stop];
        }
        _sessionSynced = YES;
        
        [self connectToControlDb];
    } else {
        LogTo(Syncpoint, @"change on local session db");
        //        re run state manager for subscription docs
        [self getUpToDateWithSubscriptions];
    }
}


- (NSString*) randomString {
    uint8_t randomBytes[16];    // 128 bits of entropy
    SecRandomCopyBytes(kSecRandomDefault, sizeof(randomBytes), randomBytes);
    return TDHexString(randomBytes, sizeof(randomBytes), true);
}


- (NSDictionary*) randomOAuthCreds {
    return $dict({@"consumer_key", [self randomString]},
                 {@"consumer_secret", [self randomString]},
                 {@"token_secret", [self randomString]},
                 {@"token", [self randomString]});
}


#pragma mark - CALLBACKS FROM AUTHENTICATOR:


- (void) authenticatedWithToken: (id)accessToken
                         ofType: (NSString*)tokenType
{
    //  it's possible we could authenticate even though we already have
    //  a Syncpoint session. This guard is to prevent extra requests.
    if (![self syncpointSessionId]) {
        // save a document that has the auth access code, to the handshake database.
        // the document also needs to have the oath credentials we'll use when replicating.
        // the server will use the access code to find the service uid, which we can use to 
        // look up the syncpoint user, and link these credentials to that user (establishing our session)
        NSDictionary *sessionData = $dict({@"type", _authenticator.authDocType},
                                          {tokenType, accessToken},
                                          {@"oauth_creds", self.randomOAuthCreds},
                                          {@"state", @"new"});
        // TODO: this document needs to have our device's SSL cert signature in it
        // so we can enforce that only this device can read this document
        LogTo(Syncpoint, @"session data %@", sessionData);
        _sessionDoc = [_sessionDatabase untitledDocument];
        RESTOperation *op = [[_sessionDoc putProperties:sessionData] start];
        [op onCompletion: ^{
            if (op.error) {
                LogTo(Syncpoint, @"op error %@",op.error);                
            } else {
                LogTo(Syncpoint, @"session doc %@",[_sessionDoc description]);
                self.syncpointSessionId = _sessionDoc.documentID;
                [self syncSessionDocument];
            }
        }];
    }
}


- (void) authenticationFailed {
    // we don't have anything really to do here
}


@end
