//
//  SyncpointAuth.h
//  Syncpoint
//
//  Created by Jens Alfke on 3/5/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
@class SyncpointClient;


/** Abstract base class for authentication/pairing services that work with Syncpoint.
    An instance is responsible for authenticating the user with some service and producing a token that can be sent to the Syncpoint server to identify and authenticate the user. */
@interface SyncpointAuthenticator : NSObject
{
    @private
    SyncpointClient* _syncpoint;
}

@property (readwrite, strong) SyncpointClient* syncpoint;

/** The "type" property value to use for session auth documents created by this instance.
    Abstract method: Subclasses must override it. */
@property (readonly) NSString* authDocType;

/** Should begin the pairing/authentication process with the service.
    This process is asynchronous; the authenticator must eventually reply to its Syncpoint instance with either an -authenticatedWithToken:ofType: message or an -authenticateionFailed message.
    Abstract method: Subclasses must override it.  */
- (void) initiatePairing;

/** If the authenticator has a stored token that's still valid, it should pass it to the Syncpoing instance by calling -authenticatedWithToken:ofType: and return YES. */
- (BOOL) validateToken;

/** Should forget any locally-stored authentication state (tokens/cookies).
    Default implementation does nothing. */
- (void) removePairing;

/** Called when the OS asks the application to open a URL.
    Many forms of authentication have the service reply to the app by redirecting Safari to a custom URL; this method allows for this.
    Default implementation just returns NO.
    @return  YES if the authenticator handled the URL, NO if it didn't. */
- (BOOL) handleOpenURL: (NSURL*)url;

@end
