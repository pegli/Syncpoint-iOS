//
//  Syncpoint.h
//  Syncpoint
//
//  Created by Jens Alfke on 2/23/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
@class Facebook, CouchServer, CouchReplication, CouchDocument;


@interface Syncpoint : NSObject
{
    @private
    NSURL* _remote;
    CouchServer* _server;
    CouchDatabase* _sessionDatabase;
    NSString* _appDatabaseName;
    CouchReplication *_sessionPull;
    CouchReplication *_sessionPush;
    CouchDocument *_sessionDoc;
    NSError* _error;
    NSString* _facebookAppID;
    Facebook *_facebook;
    BOOL _sessionSynced;
}

- (id) initWithLocalServer: (CouchServer*)localServer remoteServer: (NSURL*)remoteServerURL;
- (id) initWithRemoteServer: (NSURL*)remoteServerURL;

@property NSString* facebookAppID;
@property NSString* appDatabaseName;

@property (readonly) NSError* error;

- (BOOL) start;

- (void) initiatePairing;
- (void) removePairing;


/** Call this from your app delegate's -application:handleOpenURL: method. */
- (BOOL) handleOpenURL: (NSURL*)url;

@end
