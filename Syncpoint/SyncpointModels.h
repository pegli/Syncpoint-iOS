//
//  SyncpointModels.h
//  Syncpoint
//
//  Created by Jens Alfke on 3/7/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import <CouchCocoa/CouchModel.h>
@class SyncpointChannel, SyncpointSubscription, SyncpointInstallation;


/** Abstract base class for Syncpoint session-related model objects. */
@interface SyncpointSessionItem : CouchModel

@property NSString* state;
@property (readonly) bool isActive;

@end



/** The singleton session-control document. */
@interface SyncpointSession : SyncpointSessionItem

/** Returns the existing SyncpointSession in the session database. */
+ (SyncpointSession*) sessionInDatabase: (CouchDatabase*)database;

/** Creates a new session document in the session database.
    @param database  The local server's session database.
    @param type  The value the documents "type" property should have.
    @param tokenType  The property name of the document's auth token.
    @param token  The value of the auth token.
    @return  The new SyncpointSession instance. */
+ (SyncpointSession*) makeSessionInDatabase: (CouchDatabase*)database
                                   withType: (NSString*)type
                                  tokenType: (NSString*)tokenType
                                      token: (NSString*)token;

@property NSDictionary* oauth_creds;

@property (readonly) NSString* user_id;

/** The name of the remote control database that the session database syncs with. */
@property (readonly) NSString* controlDatabaseName;

- (SyncpointChannel*) channelWithName: (NSString*)name;

/** Creates a new channel document. */
- (SyncpointChannel*) makeChannelWithName: (NSString*)name;

- (SyncpointInstallation*) installChannelNamed: (NSString*)name
                                    toDatabase: (CouchDatabase*)localDatabase;

/** Enumerates all channels of this session that are in the "ready" state. */
@property (readonly) NSEnumerator* readyChannels;

/** Enumerates all subscriptions in this session that are in the "active" state. */
@property (readonly) NSEnumerator* activeSubscriptions;

/** All subscriptions in this session that have installations associated with them. */
@property (readonly) NSSet* installedSubscriptions;

/** Enumerates all installations of subscriptions in this session. */
@property (readonly) NSEnumerator* allInstallations;

@end



@interface SyncpointChannel : SyncpointSessionItem

@property NSString* name;
@property (readonly) bool isDefault;
@property (readonly) bool isReady;
@property (readonly) NSString* cloud_database;

@property (readonly) SyncpointSubscription* subscription;
@property (readonly) SyncpointInstallation* installation;

- (SyncpointSubscription*) makeSubscription;

@end



@interface SyncpointSubscription : SyncpointSessionItem

@property SyncpointChannel* channel;

/** Installs a channel, so it will sync with a local database.
    @param localDB  A local database to sync the channel with, or nil to create one with a random name. */
- (SyncpointInstallation*) makeInstallationWithLocalDatabase: (CouchDatabase*)localDatabase;

@end



@interface SyncpointInstallation : SyncpointSessionItem

@property (readonly) CouchDatabase* localDatabase;
@property SyncpointSubscription* subscription;
@property SyncpointChannel* channel;
@property SyncpointSession* session;

@end