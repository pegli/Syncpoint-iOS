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
    CouchDocument *_sessionDoc;
    CouchReplication *_sessionPull;
    CouchReplication *_sessionPush;
    BOOL _observingSessionPull;
    BOOL _sessionSynced;
    NSString* _appDatabaseName;
}

- (id) initWithLocalServer: (CouchServer*)localServer
              remoteServer: (NSURL*)remoteServerURL
             authenticator: (SyncpointAuth*)authenticator
                     error: (NSError**)outError;

@property NSString* appDatabaseName;

- (void) initiatePairing;

/** Call this from your app delegate's -application:handleOpenURL: method.
    @return  YES if Syncpoint's authenticator handled the URL, else NO. */
- (BOOL) handleOpenURL: (NSURL*)url;



/** Should be called only by the authenticator. */
- (void) authenticatedWithToken: (id)accessToken
                         ofType: (NSString*)tokenType;
- (void) authenticationFailed;

@end
