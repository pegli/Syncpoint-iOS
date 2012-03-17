//
//  SyncpointClient.m
//  Syncpoint
//
//  Created by Jens Alfke on 2/23/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "SyncpointClient.h"
#import "SyncpointAuthenticator.h"
#import "SyncpointModels.h"
#import "SyncpointInternal.h"
#import "CouchCocoa.h"
#import "TDMisc.h"


#define kSessionDatabaseName @"sessions"


@interface SyncpointClient ()
@property (readwrite, nonatomic) SyncpointState state;
@end


@implementation SyncpointClient
{
    @private
    NSURL* _remote;
    CouchServer* _server;
    CouchDatabase* _sessionDatabase;
    SyncpointSession* _session;
    CouchReplication *_sessionPull;
    CouchReplication *_sessionPush;
    SyncpointAuthenticator* _authenticator;
    BOOL _observingSessionPull;
    SyncpointState _state;
}


@synthesize localServer=_server, state=_state, session=_session;


- (id) initWithLocalServer: (CouchServer*)localServer
              remoteServer: (NSURL*)remoteServerURL
                     error: (NSError**)outError
{
    CAssert(localServer);
    CAssert(remoteServerURL);
    self = [super init];
    if (self) {
        _server = localServer;
        _remote = remoteServerURL;
        
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
            } else if (nil != _session.error) {
                LogTo(Syncpoint, @"Session has error: %@", _session.error.localizedDescription);
                _state = kSyncpointHasError;
                [self activateSession];
            } else {
                LogTo(Syncpoint, @"Session is not active");
                [self activateSession];
            }
        } else {
            LogTo(Syncpoint, @"No session -- authentication needed");
            _state = kSyncpointUnauthenticated;
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


#pragma mark - AUTHENTICATION:


- (void) authenticate: (SyncpointAuthenticator*)authenticator {
    LogTo(Syncpoint, @"Authenticating using %@...", authenticator);
    self.state = kSyncpointAuthenticating;
    _authenticator = authenticator;
    authenticator.syncpoint = self;
    [authenticator initiatePairing];
}


- (BOOL) handleOpenURL: (NSURL*)url {
    return [_authenticator handleOpenURL: url];
}


- (void) authenticator: (SyncpointAuthenticator*)authenticator
authenticatedWithToken: (id)accessToken
                ofType: (NSString*)tokenType
{
    if (authenticator != _authenticator || _session.isActive)
        return;
    
    LogTo(Syncpoint, @"Authenticated! %@=\"%@\"", tokenType, accessToken);
    _session = [SyncpointSession makeSessionInDatabase: _sessionDatabase
                                              withType: authenticator.authDocType
                                             tokenType: tokenType
                                                 token: accessToken
                                                 error: nil];   // TOD: Report error
    _authenticator = nil;
    if (_session)
        [self activateSession];
    else
        self.state = kSyncpointUnauthenticated;
}


- (void) authenticator: (SyncpointAuthenticator*)authenticator
       failedWithError: (NSError*)error
{
    if (authenticator != _authenticator || _session.isActive)
        return;
    LogTo(Syncpoint, @"Authentication failed or canceled");
    _authenticator = nil;
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
    [_session clearState: nil];
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
    } else if (_state != kSyncpointHasError) {
        NSError* error = _session.error;
        if (error) {
            self.state = kSyncpointHasError;
            LogTo(Syncpoint, @"Session has error: %@", error);
        }
    }
}


// Start bidirectional sync with the control database.
- (void) connectToControlDB {
    NSString* controlDBName = _session.control_database;
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
        _sessionPull = [self pullSessionFromDatabaseNamed: _session.control_database];
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
            [sub makeInstallationWithLocalDatabase: nil error: nil];    // TODO: Report error
        }

    }
    // Sync all installations whose channels are ready:
    for (SyncpointInstallation* inst in _session.allInstallations)
        if (inst.channel.isReady)
            [self syncInstallation: inst];
}


// Starts bidirectional sync of an application database with its server counterpart.
- (void) syncInstallation: (SyncpointInstallation*)installation {
    CouchDatabase *localChannelDb = installation.localDatabase;
    NSURL *cloudChannelURL = [NSURL URLWithString: installation.channel.cloud_database
                                    relativeToURL: _remote];
    LogTo(Syncpoint, @"Syncing local db '%@' with remote %@", localChannelDb, cloudChannelURL);
    NSArray* repls = [localChannelDb replicateWithURL: cloudChannelURL exclusively: NO];
    for (CouchPersistentReplication* repl in repls)
        repl.continuous = YES;
}


@end
