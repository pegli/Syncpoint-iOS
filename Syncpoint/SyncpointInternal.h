//
//  SyncpointInternal.h
//  Syncpoint
//
//  Created by Jens Alfke on 3/10/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "SyncpointClient.h"
#import "SyncpointModels.h"


@interface SyncpointModel ()
@property NSString* state;
@end



@interface SyncpointSession ()

/** Returns the existing SyncpointSession in the local control database. */
+ (SyncpointSession*) sessionInDatabase: (CouchDatabase*)database;

/** Creates a new session document in the local control database.
    @param database  The local server's control database.
    @param type  The value the documents "type" property should have.
    @param tokenType  The property name of the document's auth token.
    @param token  The value of the auth token.
    @return  The new SyncpointSession instance. */
+ (SyncpointSession*) makeSessionInDatabase: (CouchDatabase*)database
                                   withType: (NSString*)type
                                  tokenType: (NSString*)tokenType
                                      token: (NSString*)token
                                      error: (NSError**)outError;

@property (readwrite) NSDictionary* oauth_creds;

/** The name of the remote database that the local control database syncs with. */
@property (readonly) NSString* control_database;

- (BOOL) clearState: (NSError**)outError;

@end



@interface SyncpointChannel ()

@property (readwrite) NSString* name;

/** The name of the server-side database to sync subscriptions with. */
@property (readonly) NSString* cloud_database;

@end



@interface SyncpointSubscription ()

@property (readwrite) SyncpointChannel* channel;

@end



@interface SyncpointInstallation ()

@property (readwrite) SyncpointSubscription* subscription;
@property (readwrite) SyncpointChannel* channel;
@property (readwrite) SyncpointSession* session;

@end