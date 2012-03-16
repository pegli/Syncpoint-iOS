//
//  SyncpointClient.h
//  Syncpoint
//
//  Created by Jens Alfke on 2/23/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
@class SyncpointAuthenticator, CouchServer, SyncpointSession, SyncpointInstallation;


typedef enum {
    kSyncpointHasError,         /**< Server failed to authenticate/activate. */
    kSyncpointUnauthenticated,  /**< No session, and no auth token to pair with */
    kSyncpointAuthenticating,   /**< Authenticating user credentials (e.g. by OAuth) */
    kSyncpointActivating,       /**< Got auth token, now setting up with the server */
    kSyncpointUpdatingSession,  /**< Syncing session changes with the server */
    kSyncpointReady             /**< In sync with the server, ready to go */
} SyncpointState;


/** Syncpoint client-side controller: pairs with the server and tracks channels and subscriptions. */
@interface SyncpointClient : NSObject

/** Initializes a SyncpointClient instance.
    @param localServer  The application's local server object.
    @param remoteServer  The URL of the remote Syncpoint-enabled server.
    @param error  If initialization fails, this parameter will be filled in with an error.
    @return  The Syncpoint instance, or nil on failure. */
- (id) initWithLocalServer: (CouchServer*)localServer
              remoteServer: (NSURL*)remoteServerURL
                     error: (NSError**)error;

@property (readonly, nonatomic) CouchServer* localServer;

/** Current state (see SyncpointState enum above). Observable. */
@property (readonly, nonatomic) SyncpointState state;

/** Begins the process of authentication and provisioning an app database. */
- (void) authenticate: (SyncpointAuthenticator*)authenticator;


/** The session object, which manages channels and subscriptions. */
@property (readonly) SyncpointSession* session;

/** Call this from your app delegate's -application:handleOpenURL: method.
    @return  YES if Syncpoint's authenticator handled the URL, else NO. */
- (BOOL) handleOpenURL: (NSURL*)url;



/** Should be called only by the authenticator. */
- (void) authenticator: (SyncpointAuthenticator*)authenticator
authenticatedWithToken: (id)accessToken
                ofType: (NSString*)tokenType;
- (void) authenticator: (SyncpointAuthenticator*)authenticator
       failedWithError: (NSError*)error;

@end
