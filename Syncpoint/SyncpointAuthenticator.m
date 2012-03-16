//
//  SyncpointAuth.m
//  Syncpoint
//
//  Created by Jens Alfke on 3/5/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "SyncpointAuthenticator.h"
#import "SyncpointClient.h"
#import "TDMisc.h"


@implementation SyncpointAuthenticator


@synthesize syncpoint=_syncpoint;


- (NSString*) authDocType {
    AssertAbstractMethod();
}


- (void) initiatePairing {
    AssertAbstractMethod();
}


- (BOOL) validateToken {
    AssertAbstractMethod();
}


- (void) removePairing {
}


- (BOOL) handleOpenURL: (NSURL*)url {
    return NO;
}


@end
