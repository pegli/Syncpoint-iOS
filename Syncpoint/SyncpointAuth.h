//
//  SyncpointAuth.h
//  Syncpoint
//
//  Created by Jens Alfke on 3/5/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
@class Syncpoint;


/** Abstract base class for authentication/pairing services that work with Syncpoint.
    An instance is responsible for authenticating the user with some service and producing a token that can be sent to the Syncpoint server to identify and authenticate the user. */
@interface SyncpointAuth : NSObject
{
    @private
    Syncpoint* _syncpoint;
}

@property (readwrite) Syncpoint* syncpoint;

/** The "type" property value to use for session auth documents created by this instance. */
@property (readonly) NSString* authDocType;

/** Should begin the pairing/authentication process with the service.
    This process is asynchronous; the authenticator must eventually reply to its Syncpoint instance with either an -authenticatedWithToken:ofType: message or an -authenticateionFailed message. */
- (void) initiatePairing;

/** Should forget any locally-stored authentication state (tokens/cookies). */
- (void) removePairing;

/** Called when the OS asks the application to open a URL.
    Many forms of authentication have the service reply to the app by redirecting Safari to a custom URL; this method allows for this.
    @return  YES if the authenticator handled the URL, NO if it didn't. */
- (BOOL) handleOpenURL: (NSURL*)url;

@end
