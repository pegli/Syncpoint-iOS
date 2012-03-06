//
//  Syncpoint.h
//  Syncpoint
//
//  Created by Jens Alfke on 2/23/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
@class SyncpointAuth, CouchServer, CouchReplication, CouchDocument;


/** Syncpoint client-side controller: pairs with the server and tracks channels and subscriptions. */
@interface Syncpoint : NSObject
{
    @private
    SyncpointAuth* _authenticator;
    NSURL* _remote;
    CouchServer* _server;
    CouchDatabase* _sessionDatabase;
    NSString* _appDatabaseName;
    CouchReplication *_sessionPull;
    CouchReplication *_sessionPush;
    BOOL _observingSessionPull;
    CouchDocument *_sessionDoc;
    NSError* _error;
    BOOL _sessionSynced;
}

- (id) initWithLocalServer: (CouchServer*)localServer
              remoteServer: (NSURL*)remoteServerURL
             authenticator: (SyncpointAuth*)authenticator;

@property NSString* appDatabaseName;

@property (readonly) NSError* error;

- (BOOL) start;

- (void) initiatePairing;

/** Call this from your app delegate's -application:handleOpenURL: method.
    @return  YES if Syncpoint's authenticator handled the URL, else NO. */
- (BOOL) handleOpenURL: (NSURL*)url;



/** Should be called only by the authenticator. */
- (void) authenticatedWithToken: (id)accessToken
                         ofType: (NSString*)tokenType;
- (void) authenticationFailed;

@end
