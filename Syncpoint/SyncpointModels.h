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
@interface SyncpointModel : CouchModel

/** Has this object been registered with the server? */
@property (readonly) bool isActive;

@end



/** The singleton session-control document. */
@interface SyncpointSession : SyncpointModel

/** The server-assigned ID of the local user. */
@property (readonly) NSString* user_id;

/** Server-side error, if the server's unable to authenticate the user's credentials. */
@property (readonly) NSError* error;

/** Returns the existing channel with the given name, or nil if it doesn't exist. */
- (SyncpointChannel*) channelWithName: (NSString*)name;

/** Creates a new channel document.
    Channel names are not unique; if there is already a channel with this name, a new one will be created. */
- (SyncpointChannel*) makeChannelWithName: (NSString*)name
                                    error: (NSError**)error;

/** Convenience method that creates a channel if none with that name exists, then creates a subscription to it, synchronizing it with a local database.
    It is OK to call this before the session has been activated. The request will be queued, and the installation created as soon as the session goes live.
    @param channelName  The channel name. If a channel with this name doesn't exist, it will be created.
    @param localDatabase  The database on the local server to sync the channel database with. If it doesn't exist yet, it will be created. Or pass nil to have a new randomly-named database created.
    @param error  On failure, will be filled in with an NSError describing the problem.
    @return  On success, an object representing the installation. On failure (or if the installation is deferred because the session isn't active yet), nil. */
- (SyncpointInstallation*) installChannelNamed: (NSString*)channelName
                                    toDatabase: (CouchDatabase*)localDatabase
                                         error: (NSError**)error;

/** Enumerates all channels of this session that are in the "ready" state. */
@property (readonly) NSEnumerator* readyChannels;

/** Enumerates all subscriptions in this session that are in the "active" state. */
@property (readonly) NSEnumerator* activeSubscriptions;

/** All subscriptions in this session that have installations associated with them. */
@property (readonly) NSSet* installedSubscriptions;

/** Enumerates all installations of subscriptions in this session. */
@property (readonly) NSEnumerator* allInstallations;

@end



/** A channel represents a database available on the server that you could subscribe to. */
@interface SyncpointChannel : SyncpointModel

/** The channel's name. Not guaranteed to be unique. */
@property (readonly) NSString* name;

/** The ID of the user who created/owns this channel.
    Not necessarily the same as the ID of the local user! */
@property (readonly) NSString* owner_id;

/** Is the channel set up on the server and ready for use? */
@property (readonly) bool isReady;

/** The local user's subscription to the channel, if any. */
@property (readonly) SyncpointSubscription* subscription;

/** The local device's installation of the channel, if any. */
@property (readonly) SyncpointInstallation* installation;

/** Creates a subscription to this channel. */
- (SyncpointSubscription*) subscribe: (NSError**)error;

/** Creates a subscription and local installation of this channel, synced to the given database.
    If a subscription already exists, it'll be reused without creating a duplicate.
    If a local installation already exists, it'll be returned without creating a duplicate.
    @param localDatabase  The local database to sync the channel with, or nil to create a new local database (with a randomly chosen name.)
    @param error  On failure, will be filled in with an NSError.
    @return  The new installation object, or nil on failure. */
- (SyncpointInstallation*) makeInstallationWithLocalDatabase: (CouchDatabase*)localDatabase
                                                       error: (NSError**)error;

@end



/** A subscription represents a channel that your user account has subscribed to, on some device or devices (but not necessarily this one.)
    If the local device is subscribed to a channel, there will also be a corresponding SyncpointInstallation. */
@interface SyncpointSubscription : SyncpointModel

/** The channel being subscribed to. */
@property (readonly) SyncpointChannel* channel;

/** The local installation of this subscription, if this device is subscribed. */
@property (readonly) SyncpointInstallation* installation;

/** Creates a local installation of this channel, synced to the given database.
    This doesn't care whether a local installation already exists -- if so, you'll now have two,
    which can be confusing (and duplicates bandwidth) and is probably not what you wanted.
    @param localDB  A local database to sync the channel with, or nil to create one with a random name.
    @param error  On failure, will be filled in with an NSError.
    @return  The new installation object, or nil on failure. */
- (SyncpointInstallation*) makeInstallationWithLocalDatabase: (CouchDatabase*)localDatabase
                                                       error: (NSError**)error;

- (BOOL) unsubscribe: (NSError**)outError;

@end



/** An installation represents a subscription to a channel on a specific device. */
@interface SyncpointInstallation : SyncpointModel

/** Is this installation specific to this device? */
@property (readonly) bool isLocal;

/** The local database to sync. */
@property (readonly) CouchDatabase* localDatabase;

/** The subscription this is associated with. */
@property (readonly) SyncpointSubscription* subscription;

/** The channel this is associated with. */
@property (readonly) SyncpointChannel* channel;

/** The session this is associated with. */
@property (readonly) SyncpointSession* session;

- (BOOL) uninstall: (NSError**)outError;

@end
