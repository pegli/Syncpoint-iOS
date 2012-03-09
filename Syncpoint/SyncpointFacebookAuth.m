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
        LogTo(Syncpoint, @"Created Facebook instance %@; token=%@, expiration=%@",
              _facebook, accessToken, expirationDate);
        if (accessToken && expirationDate) {
            _facebook.accessToken = accessToken;
            _facebook.expirationDate = expirationDate;
        }
    }
    return _facebook;
}


- (void) initiatePairing {
    if (![self validateToken]) {
        LogTo(Syncpoint, @"Authorizing with Facebook...");
        [_facebook authorize:nil];
    }
}


- (BOOL) validateToken {
    Assert(self.syncpoint);
    if (!self.facebook.isSessionValid)
        return NO;
    [self.syncpoint authenticatedWithToken: _facebook.accessToken ofType: @"fb_access_token"];
    return YES;
}


- (void) removePairing {
    //    todo: delete the session document
    //    [sessionDocument delete]
    [self forgetToken];
    [self.facebook logout];
}


- (BOOL) handleOpenURL: (NSURL*)url {
    return [_facebook handleOpenURL:url];
}


- (void) setToken: (NSString*)accessToken expirationDate: (NSDate*)expirationDate {
    LogTo(Syncpoint, @"Facebook logged in: token=%@, expiration=%@", accessToken, expirationDate);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject: accessToken forKey: @"Syncpoint_FBAccessToken"];
    [defaults setObject: expirationDate forKey: @"Syncpoint_FBExpirationDate"];
    [defaults synchronize];
    [self.syncpoint authenticatedWithToken: accessToken ofType: @"fb_access_token"];
}

- (void) forgetToken {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey: @"Syncpoint_FBAccessToken"];
    [defaults removeObjectForKey: @"Syncpoint_FBExpirationDate"];
}


#pragma mark - FACEBOOK DELEGATE API:


- (void) fbDidLogin {
    [self setToken: _facebook.accessToken expirationDate: _facebook.expirationDate];
}

// Called when the user canceled the authorization dialog.
-(void) fbDidNotLogin: (BOOL)cancelled {
    LogTo(Syncpoint, @"Facebook did not login; cancelled=%d", cancelled);
    [self.syncpoint authenticationFailed];
}


- (void) fbDidExtendToken: (NSString*)accessToken
                expiresAt: (NSDate*)expiresAt
{
    [self setToken: accessToken expirationDate: expiresAt];
}

- (void) fbDidLogout {
    [self forgetToken];
}

- (void) fbSessionInvalidated {
    [self forgetToken];
}


@end
