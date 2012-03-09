//
//  Syncpoint.h
//  Syncpoint
//
//  Created by Jens Alfke on 2/23/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
@class SyncpointAuth, CouchServer, CouchReplication, CouchDocument, SyncpointSession;


typedef enum {
    kSyncpointUnauthenticated,
    kSyncpointAuthenticating,
    kSyncpointActivating,
    kSyncpointUpdatingSession,
    kSyncpointReady
} SyncpointState;


/** Syncpoint client-side controller: pairs with the server and tracks channels and subscriptions. */
@interface Syncpoint : NSObject
{
    @private
    SyncpointAuth* _authenticator;
    NSURL* _remote;
    CouchServer* _server;
    CouchDatabase* _sessionDatabase;
    SyncpointSession* _session;
    CouchReplication *_sessionPull;
    CouchReplication *_sessionPush;
    BOOL _observingSessionPull;
    NSString* _appDatabaseName;
    SyncpointState _state;
    
}

/** Initializes a Syncpoint instance.
    @param localServer  The application's local server object.
    @param remoteServer  The URL of the remote Syncpoint-enabled server.
    @param authenticator  An object that manages user authentication.
    @param error  If this method returns nil, this parameter will be filled in with an error. */
- (id) initWithLocalServer: (CouchServer*)localServer
              remoteServer: (NSURL*)remoteServerURL
             authenticator: (SyncpointAuth*)authenticator
                     error: (NSError**)outError;

/** Current state (see SyncpointState enum above). */
@property (readonly, nonatomic) SyncpointState state;

/** The name of the database the app wants to use for its data.
    TEMPORARY! Will be replaced by a more flexible API in the future, allowing for multiple databases. */
@property NSString* appDatabaseName;

/** Begins the process of authentication and provisioning an app database. */
- (void) initiatePairing;

/** Call this from your app delegate's -application:handleOpenURL: method.
    @return  YES if Syncpoint's authenticator handled the URL, else NO. */
- (BOOL) handleOpenURL: (NSURL*)url;



/** Should be called only by the authenticator. */
- (void) authenticatedWithToken: (id)accessToken
                         ofType: (NSString*)tokenType;
- (void) authenticationFailed;

@end
