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


@implementation Syncpoint


@synthesize appDatabaseName=_appDatabaseName;


- (id) initWithLocalServer: (CouchServer*)localServer
              remoteServer: (NSURL*)remoteServerURL
             authenticator: (SyncpointAuth*)authenticator
                     error: (NSError**)outError
{
    CAssert(localServer);
    CAssert(remoteServerURL);
    CAssert(authenticator);
    self = [super init];
    if (self) {
        _server = localServer;
        _remote = remoteServerURL;
        _authenticator = authenticator;
        _authenticator.syncpoint = self;
        
        // Create the session database on the first run of the app.
        _sessionDatabase = [_server databaseNamed: kSessionDatabaseName];
        if (![_sessionDatabase ensureCreated: outError])
            return nil;
        _sessionDatabase.tracksChanges = YES;

        NSString* sessionID = self.syncpointSessionID;
        if (sessionID) {
            _sessionDoc = [_sessionDatabase documentWithID: sessionID];
            if (!_sessionDoc.properties) {
                // Oops -- the session ID in user-defaults is out of date, so clear it
                _sessionDoc = nil;
                self.syncpointSessionID = nil;
                sessionID = nil;
            }
        }
            
        if (sessionID) {
            if (self.sessionIsActive) {
                // Setup sync with the user control database
                LogTo(Syncpoint, @"Session is active");
                _sessionSynced = YES;
                [self connectToControlDB];
                [self observeSessionDatabase];
            } else {
                LogTo(Syncpoint, @"Session is not active");
                [self syncSessionDocument];
            }
        } else {
            LogTo(Syncpoint, @"No session -- pairing needed");
        }
    }
    return self;
}


- (void)dealloc
{
    _authenticator.syncpoint = nil;
    [self stopObservingSessionPull];
    [[NSNotificationCenter defaultCenter] removeObserver: self];
}


- (void) initiatePairing {
    [_authenticator initiatePairing];
}


- (BOOL) handleOpenURL: (NSURL*)url {
    return [_authenticator handleOpenURL: url];
}


#pragma mark - CALLBACKS FROM AUTHENTICATOR:


- (void) authenticatedWithToken: (id)accessToken
                         ofType: (NSString*)tokenType
{
    //  it's possible we could authenticate even though we already have
    //  a Syncpoint session. This guard is to prevent extra requests.
    if (self.syncpointSessionID)
        return;
    
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
    LogTo(Syncpoint, @"Authenticating to server -- session data %@", sessionData);
    _sessionDoc = [_sessionDatabase untitledDocument];
    RESTOperation *op = [[_sessionDoc putProperties: sessionData] start];
    [op onCompletion: ^{
        if (op.error) {
            LogTo(Syncpoint, @"Auth failed, error %@",op.error);                
        } else {
            LogTo(Syncpoint, @"Created session doc %@", _sessionDoc);
            self.syncpointSessionID = _sessionDoc.documentID;
            [self syncSessionDocument];
        }
    }];
}


- (void) authenticationFailed {
    LogTo(Syncpoint, @"Authentication failed or canceled");
}


#pragma mark - SESSION DATABASE & SYNC:


- (CouchReplication*) pullSessionFromDatabaseNamed: (NSString*)dbName {
    NSURL* url = [NSURL URLWithString: dbName relativeToURL: _remote];
    return [_sessionDatabase pullFromDatabaseAtURL: url];
}

- (CouchReplication*) pushSessionToDatabaseNamed: (NSString*)dbName {
    NSURL* url = [NSURL URLWithString: dbName relativeToURL: _remote];
    return [_sessionDatabase pushToDatabaseAtURL: url];
}


// Starts an async bidirectional sync of the _sessionDoc in the _sessionDatabase.
- (void) syncSessionDocument {
    LogTo(Syncpoint, @"Syncing session document...");
    [self pushSessionToDatabaseNamed: kSessionDatabaseName];
    _sessionPull = [self pullSessionFromDatabaseNamed: kSessionDatabaseName];
    _sessionPull.filter = @"_doc_ids";
    _sessionPull.filterParams = $dict({@"doc_ids", $sprintf(@"[\"%@\"]", _sessionDoc.documentID)});
    _sessionPull.continuous = YES;
    [_sessionPull start];
    
    //    ok now we should listen to changes on the session db and stop replication 
    //    when we get our doc back in a finalized state
    _sessionSynced = NO;
    [self observeSessionDatabase];
}


// Begins observing document changes in the _sessionDatabase.
- (void) observeSessionDatabase {
    Assert(_sessionDatabase);
    LogTo(Syncpoint, @"observing session db");
    [[NSNotificationCenter defaultCenter] addObserver: self 
                                             selector: @selector(sessionDatabaseChanged)
                                                 name: kCouchDatabaseChangeNotification 
                                               object: _sessionDatabase];
}

- (void)sessionDatabaseChanged {
    if (_sessionSynced) {
        LogTo(Syncpoint, @"Session DB changed");
        //        re run state manager for subscription docs
        [self getUpToDateWithSubscriptions];
        
    } else if (self.sessionIsActive) {
        LogTo(Syncpoint, @"Session is now active!");
        _sessionSynced = YES;
        
        [_sessionPull stop];
        _sessionPull = nil;
        [_sessionPush stop];
        _sessionPush = nil;
        
        [self connectToControlDB];
    }
}


// Start bidirectional sync with the control database.
- (void) connectToControlDB {
    Assert(self.sessionIsActive);
    NSString* controlDBName = self.controlDBName;
    LogTo(Syncpoint, @"Connecting to control database %@",controlDBName);
    Assert(controlDBName);
    
    // During the initial sync, make the pull non-continuous, and observe when it stops.
    // That way we know when the session DB has been populated from the server.
    _sessionPull = [self pullSessionFromDatabaseNamed: controlDBName];
    [_sessionPull addObserver: self forKeyPath: @"running" options: 0 context: NULL];
    _observingSessionPull = YES;
    
    _sessionPush = [self pushSessionToDatabaseNamed: controlDBName];
    _sessionPush.continuous = YES;
}


// Observes when the initial _sessionPull stops running, after -connectToControlDB.
- (void) observeValueForKeyPath: (NSString*)keyPath ofObject: (id)object 
                         change: (NSDictionary*)change context: (void*)context
{
    if (object == _sessionPull && !_sessionPull.running) {
        LogTo(Syncpoint, @"Finished first session pull");
        [self stopObservingSessionPull];
        // Now start the pull up again:
        _sessionPull = [self pullSessionFromDatabaseNamed: self.controlDBName];
        _sessionPull.continuous = YES;

        [self maybeInitializeChannel: _appDatabaseName];
        [self getUpToDateWithSubscriptions];
    }
}


- (void) stopObservingSessionPull {
    if (_observingSessionPull) {
        [_sessionPull removeObserver: self forKeyPath: @"running"];
        _observingSessionPull = NO;
    }
}


// Called when the session database changes or is pulled from the server.
- (void) getUpToDateWithSubscriptions {
    for (CouchDocument* needInstall in self.activeSubscriptionsWithoutInstallations)
        [self makeInstallationForSubscription: needInstall withDatabaseNamed: nil error: nil];
    for (CouchDocument *installation in self.createdInstallationsWithReadyChannels) 
        [self syncInstallation: installation];
}


// Starts bidirectional sync of an application database with its server counterpart.
- (void) syncInstallation: (CouchDocument*)installation {
    // TODO: setup sync with the database listed in "cloud_database" on the channel doc
    // This means we need the server side to actually make some channels "ready" first
    NSString* localDBName = [installation.properties objectForKey:@"local_db_name"];
    NSString* channelID = [installation.properties objectForKey:@"channel_id"];
    CouchDatabase *localChannelDb = [_server databaseNamed: localDBName];
    CouchDocument *channelDoc = [_sessionDatabase documentWithID: channelID];
    NSString* cloudChannelName = [channelDoc.properties objectForKey:@"cloud_database"];
    NSURL *cloudChannelURL = [NSURL URLWithString: cloudChannelName relativeToURL: _remote];
    
    LogTo(Syncpoint, @"Syncing local db '%@' with remote %@", localDBName, cloudChannelURL);
    CouchReplication *pull = [localChannelDb pullFromDatabaseAtURL:cloudChannelURL];
    pull.continuous = YES;
    CouchReplication *push = [localChannelDb pushToDatabaseAtURL:cloudChannelURL];
    push.continuous = YES;
}


#pragma mark - SUBSCRIPTIONS:


// Creates a subscription document for a channel.
- (CouchDocument*) makeSubscriptionForChannel: (CouchDocument*)channel
{
    LogTo(Syncpoint, @"Creating subscription doc for channel %@", channel);
    CouchDocument *subscription = [_sessionDatabase untitledDocument];
    RESTOperation* op = [subscription putProperties: $dict(
                           {@"type", @"subscription"},
                           {@"state", @"active"},
                           {@"owner_id", self.myUserID},
                           {@"channel_id", channel.documentID})];
    if (![[op start] wait]) {
        LogTo(Syncpoint, @"could not create subscription doc: %@", op.error);
        return nil;
    }
    return subscription;
}


// Creates a channel database and installation document for a subscription.
- (CouchDocument*) makeInstallationForSubscription: (CouchDocument*)subscription
                                 withDatabaseNamed: (NSString*)name
                                             error: (NSError**)outError
{
    if (!name)
        name = [@"channel-" stringByAppendingString:[self randomString]];
    LogTo(Syncpoint, @"Creating installation DB %@ for subscription %@", name, subscription);
    
    // Create the channel database:
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


- (CouchDocument*) maybeInitializeChannel: (NSString*)localDatabaseName {
    //    if we have a channel owned by the user, and it is flagged default == true,
    //    then we don't need to make a channel doc or a subscription,
    //    but we do need to make an installation doc that references the subscription.
    
    //    if we don't have a default channel owned by the user, 
    //    then we need to create it, and a subcription to it (by the owner).
    //    also we create an installation doc linking the kDatabaseName (pre-pairing) database
    //    with the channel & subscription.
    
    //    note: need a channel doc and a subscription doc only makes sense when you need to 
    //    allow for channels that are shared by multiple users.
    LogTo(Syncpoint, @"Creating subscription/installation for db %@", localDatabaseName);
    CouchDocument* channel = self.defaultChannelDocument;
    CouchDocument* subscription = nil; // user
    CouchDocument* installation = nil; // per session
    if (channel) {
        // Default channel exists; look for corresponding subscription & installation:
        // TODO: use a query
        for (CouchQueryRow* row in [[_sessionDatabase getAllDocuments] rows]) {
            NSDictionary* docProps = row.documentProperties;
            if ([[docProps objectForKey:@"local_db_name"] isEqual: localDatabaseName]
                    && [[docProps objectForKey:@"session_id"] isEqual: _sessionDoc.documentID]
                    && [[docProps objectForKey:@"channel_id"] isEqual: channel.documentID]) {
                installation =  row.document;
            } else if ([[docProps objectForKey:@"type"] isEqual:@"subscription"]
                       && [[docProps objectForKey:@"owner_id"] isEqual: self.myUserID] 
                       && [[docProps objectForKey:@"channel_id"] isEqual: channel.documentID]) {
                subscription = row.document;
            }
        }
    } else {
        channel = [self createDefaultChannelDocument];
        if (!channel)
            return nil;
    }
    
    if (!subscription) {
        if (installation)
            Warn(@"already have an install doc %@ with no subscription for channel %@",
                 installation, channel);
        subscription = [self makeSubscriptionForChannel: channel];
        if (!subscription)
            return nil;
    }
    
    if (!installation) {
        installation = [self makeInstallationForSubscription: subscription
                                           withDatabaseNamed: localDatabaseName
                                                       error: nil];
    }
    return installation;
}


#pragma mark - ACCESSORS & UTILITIES


- (NSString*) controlDBName {
    return [[_sessionDoc.properties objectForKey: @"session"] objectForKey: @"control_database"];
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


- (id) syncpointSessionID {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"Syncpoint_SessionDocID"];
}

- (void) setSyncpointSessionID: (NSString*)sessionID {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject: sessionID forKey: @"Syncpoint_SessionDocID"];
    [defaults synchronize];
}


- (BOOL)sessionIsActive {
    return _sessionDoc && [[_sessionDoc.properties objectForKey:@"state"] isEqual: @"active"];
}


- (NSString*) myUserID {
    return [[_sessionDoc.properties objectForKey:@"session"] objectForKey:@"user_id"];
}


- (CouchDocument*) defaultChannelDocument {
    NSString *myUserID= self.myUserID;
    for (CouchQueryRow* row in [[_sessionDatabase getAllDocuments] rows]) {
        NSDictionary* docProps = row.documentProperties;
        if ([[docProps objectForKey:@"type"] isEqual: @"channel"]
                && [[docProps objectForKey: @"owner_id"] isEqual: myUserID]
                && ([docProps objectForKey: @"default"] == $true)) {
            return row.document;
        }
    }
    return nil;
}


- (CouchDocument*) createDefaultChannelDocument {
    CouchDocument* channel = [_sessionDatabase untitledDocument];
    RESTOperation* op = [channel putProperties: $dict({@"type", @"channel"},
                                                      {@"owner_id", self.myUserID},
                                                      {@"default", $true},
                                                      {@"state", @"new"},
                                                      {@"name", @"Default List"})];
    if (![[op start] wait]) {
        Warn(@"Syncpoint: Failed to create channel doc: %@", op.error);
        channel = nil;
    }
    return channel;
}


- (NSArray*) activeSubscriptionsWithoutInstallations {
    NSMutableArray *subs = [NSMutableArray array];
    NSMutableSet *installed_sub_ids = [NSMutableSet set];
    NSString *myUserID = self.myUserID;
    for (CouchQueryRow *row in [[_sessionDatabase getAllDocuments] rows]) {
        NSDictionary* docProperties = row.documentProperties;
        if ([[docProperties objectForKey:@"type"] isEqual:@"subscription"]
                && [[docProperties objectForKey:@"owner_id"] isEqual: myUserID]
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
    NSString *myUserID = self.myUserID;
    NSMutableArray *installs = [NSMutableArray array];
    NSMutableSet *ready_channel_ids = [NSMutableSet set];
    for (CouchQueryRow *row in [[_sessionDatabase getAllDocuments] rows]) {
        NSDictionary* docProperties = row.documentProperties;
        if ([[docProperties objectForKey:@"type"] isEqual:@"installation"]
                && [[docProperties objectForKey:@"state"] isEqual:@"created"]
                && [[docProperties objectForKey:@"session_id"] isEqual:_sessionDoc.documentID]) {
            [installs addObject: row.document];
        } else if ([[docProperties objectForKey:@"type"] isEqual:@"channel"]
                   && [[docProperties objectForKey:@"state"] isEqual:@"ready"]
                   && [[docProperties objectForKey:@"owner_id"] isEqual:myUserID]) {
            [ready_channel_ids addObject: row.documentID];
        }
    }
    
    return [installs my_filter: ^int(CouchDocument* doc) {
        NSString* channelID = [doc.properties objectForKey:@"channel_id"];
        return [ready_channel_ids containsObject: channelID];
    }];
}


@end
