//
//  SyncpointFacebookAuth.m
//  Syncpoint
//
//  Created by Jens Alfke on 3/5/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "SyncpointFacebookAuth.h"
#import "Syncpoint.h"
#import "Facebook.h"


@interface SyncpointAuth () <FBSessionDelegate, FBRequestDelegate>
@end


@implementation SyncpointFacebookAuth


static NSString* sFacebookAppID;


+ (NSString*) facebookAppID {
    return sFacebookAppID;
}

+ (void) setFacebookAppID: (NSString*)facebookAppID {
    sFacebookAppID = [facebookAppID copy];
}


- (NSString*) authDocType {
    return @"session-fb";
}


- (Facebook*) facebook {
    if (!_facebook) {
        // Create the Facebook object on demand
        Assert(sFacebookAppID, @"SyncpointFacebookAuth app ID has not been set");
        _facebook = [[Facebook alloc] initWithAppId: sFacebookAppID andDelegate: self];
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        NSString* accessToken = [defaults objectForKey:@"Syncpoint_FBAccessToken"];
        NSDate* expirationDate = [defaults objectForKey:@"Syncpoint_FBExpirationDate"];
        if (accessToken && expirationDate) {
            _facebook.accessToken = accessToken;
            _facebook.expirationDate = expirationDate;
        }
    }
    return _facebook;
}


- (void) initiatePairing {
    if (!self.facebook.isSessionValid)
        [self.facebook authorize:nil];
}

- (void) removePairing {
    //    todo: delete the session document
    //    [sessionDocument delete]
    [self.facebook logout];
}


- (BOOL) handleOpenURL: (NSURL*)url {
    return [_facebook handleOpenURL:url];
}


#pragma mark - FACEBOOK DELEGATE API:


- (void) fbDidLogin {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject: _facebook.accessToken forKey: @"Syncpoint_FBAccessToken"];
    [defaults setObject: _facebook.expirationDate forKey: @"Syncpoint_FBExpirationDate"];
    [defaults synchronize];
    [self.syncpoint authenticatedWithToken: _facebook.accessToken ofType: @"fb_access_token"];
}

// Called when the user canceled the authorization dialog.
-(void) fbDidNotLogin: (BOOL)cancelled {
    [self.syncpoint authenticationFailed];
}


- (void) fbDidExtendToken: (NSString*)accessToken
                expiresAt: (NSDate*)expiresAt
{
    // TODO: IMPLEMENT
}

- (void) fbDidLogout {
    // TODO: IMPLEMENT
}

- (void) fbSessionInvalidated {
    // TODO: IMPLEMENT
}


@end
