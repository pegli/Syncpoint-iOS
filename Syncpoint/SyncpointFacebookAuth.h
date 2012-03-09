//
//  SyncpointFacebookAuth.h
//  Syncpoint
//
//  Created by Jens Alfke on 3/5/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "SyncpointAuth.h"
@class Facebook;


/** Facebook authentication mechanism for Syncpoint clients. */
@interface SyncpointFacebookAuth : SyncpointAuth
{
    @private
    Facebook *_facebook;
}

/** The application must set its Facebook-assigned ID here before pairing. */
+ (void) setFacebookAppID: (NSString*)facebookAppID;
+ (NSString*) facebookAppID;

@end
