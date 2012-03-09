//
//  Syncpoint.m
//  Syncpoint
//
//  Created by Jens Alfke on 2/23/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "Syncpoint.h"
#import "SyncpointAuth.h"
#import "SyncpointModels.h"
#import <CouchCocoa/CouchCocoa.h>
#import "TDMisc.h"


#define kSessionDatabaseName @"sessions"


@interface Syncpoint ()
@property (readwrite, nonatomic) SyncpointState state;
@end


@implementation Syncpoint


@synthesize state=_state, appDatabaseName=_appDatabaseName;


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
        _session = [SyncpointSession sessionInDatabase: _sessionDatabase];

        if (_session) {
            if (_session.isActive) {
                LogTo(Syncpoint, @"Session is active");
                [self connectToControlDB];
                [self observeSessionDatabase];
            } else {
                LogTo(Syncpoint, @"Session is not active");
                [self activateSession];
            }
        } else {
            _state = kSyncpointUnauthenticated;
            if (![_authenticator validateToken])
                LogTo(Syncpoint, @"No session -- pairing needed");
        }
    }
    return self;
}


- (void)dealloc {
    _authenticator.syncpoint = nil;
    [self stopObservingSessionPull];
    [[NSNotificationCenter defaultCenter] removeObserver: self];
}


- (BOOL) isActivated {
    return _state > kSyncpointActivating;
}


- (void) initiatePairing {
    LogTo(Syncpoint, @"Authenticating using %@...", _authenticator);
    self.state = kSyncpointAuthenticating;
    [_authenticator initiatePairing];
}


- (BOOL) handleOpenURL: (NSURL*)url {
    return [_authenticator handleOpenURL: url];
}


#pragma mark - CALLBACKS FROM AUTHENTICATOR:


- (void) authenticatedWithToken: (id)accessToken
                         ofType: (NSString*)tokenType
{
    if (_session.isActive)
        return;     // TODO: Need to update token in session doc if it's changed
    
    LogTo(Syncpoint, @"Authenticated! %@=\"%@\"", tokenType, accessToken);
    _session = [SyncpointSession makeSessionInDatabase: _sessionDatabase
                                              withType: _authenticator.authDocType
                                             tokenType: tokenType
                                                 token: accessToken];
    if (_session)
        [self activateSession];
}


- (void) authenticationFailed {
    LogTo(Syncpoint, @"Authentication failed or canceled");
    self.state = kSyncpointUnauthenticated;
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


// Starts an async bidirectional sync of the _session in the _sessionDatabase.
- (void) activateSession {
    LogTo(Syncpoint, @"Activating session document...");
    Assert(!_session.isActive);
    self.state = kSyncpointActivating;
    NSString* sessionID = _session.document.documentID;
    [self pushSessionToDatabaseNamed: kSessionDatabaseName];
    _sessionPull = [self pullSessionFromDatabaseNamed: kSessionDatabaseName];
    _sessionPull.filter = @"_doc_ids";
    _sessionPull.filterParams = $dict({@"doc_ids", $sprintf(@"[\"%@\"]", sessionID)});
    _sessionPull.continuous = YES;
    
    //    ok now we should listen to changes on the session db and stop replication 
    //    when we get our doc back in a finalized state
    [self observeSessionDatabase];
}


// Begins observing document changes in the _sessionDatabase.
- (void) observeSessionDatabase {
    Assert(_sessionDatabase);
    [[NSNotificationCenter defaultCenter] addObserver: self 
                                             selector: @selector(sessionDatabaseChanged)
                                                 name: kCouchDatabaseChangeNotification 
                                               object: _sessionDatabase];
}

- (void) sessionDatabaseChanged {
    if (_state > kSyncpointActivating) {
        LogTo(Syncpoint, @"Session DB changed");
        [self getUpToDateWithSubscriptions];
        
    } else if (_session.isActive) {
        LogTo(Syncpoint, @"Session is now active!");
        [_sessionPull stop];
        _sessionPull = nil;
        [_sessionPush stop];
        _sessionPush = nil;
        [self connectToControlDB];
    }
}


// Start bidirectional sync with the control database.
- (void) connectToControlDB {
    NSString* controlDBName = _session.controlDatabaseName;
    LogTo(Syncpoint, @"Syncing with control database %@", controlDBName);
    Assert(controlDBName);
    
    // During the initial sync, make the pull non-continuous, and observe when it stops.
    // That way we know when the session DB has been updated from the server.
    _sessionPull = [self pullSessionFromDatabaseNamed: controlDBName];
    [_sessionPull addObserver: self forKeyPath: @"running" options: 0 context: NULL];
    _observingSessionPull = YES;
    
    _sessionPush = [self pushSessionToDatabaseNamed: controlDBName];
    _sessionPush.continuous = YES;

    self.state = kSyncpointUpdatingSession;
}


// Observes when the initial _sessionPull stops running, after -connectToControlDB.
- (void) observeValueForKeyPath: (NSString*)keyPath ofObject: (id)object 
                         change: (NSDictionary*)change context: (void*)context
{
    if (object == _sessionPull && !_sessionPull.running) {
        LogTo(Syncpoint, @"Up-to-date with control database");
        [self stopObservingSessionPull];
        // Now start the pull up again, in continuous mode:
        _sessionPull = [self pullSessionFromDatabaseNamed: _session.controlDatabaseName];
        _sessionPull.continuous = YES;
        self.state = kSyncpointReady;
        LogTo(Syncpoint, @"**READY**");

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
    // Make installations for any subscriptions that don't have one:
    NSSet* installedSubscriptions = _session.installedSubscriptions;
    for (SyncpointSubscription* sub in _session.activeSubscriptions) {
        if (![installedSubscriptions containsObject: sub]) {
            LogTo(Syncpoint, @"Making installation db for %@", sub);
            [sub makeInstallationWithLocalDatabase: nil];
        }

    }
    // Sync all installations whose channels are ready:
    for (SyncpointInstallation* inst in _session.allInstallations)
        if (inst.channel.isReady)
            [self syncInstallation: inst];
}


- (SyncpointInstallation*) installChannelNamed: (NSString*)name
                                    toDatabase: (CouchDatabase*)localDatabase
{
    LogTo(Syncpoint, @"Installing channel named '%@' for %@", name, localDatabase);
    SyncpointInstallation* inst = [_session installChannelNamed: name toDatabase: localDatabase];
    if (inst.channel.isReady)
        [self syncInstallation: inst];
    return inst;
}


// Starts bidirectional sync of an application database with its server counterpart.
- (void) syncInstallation: (SyncpointInstallation*)installation {
    CouchDatabase *localChannelDb = installation.localDatabase;
    NSURL *cloudChannelURL = [NSURL URLWithString: installation.channel.cloud_database
                                    relativeToURL: _remote];
    LogTo(Syncpoint, @"Syncing local db '%@' with remote %@", localChannelDb, cloudChannelURL);
    CouchReplication *pull = [localChannelDb pullFromDatabaseAtURL:cloudChannelURL];
    pull.continuous = YES;
    CouchReplication *push = [localChannelDb pushToDatabaseAtURL:cloudChannelURL];
    push.continuous = YES;
}


@end
