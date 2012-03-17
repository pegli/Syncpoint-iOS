//
//  DemoAppController.m
//  CouchCocoa
//
//  Created by Jens Alfke on 6/1/11.
//  Copyright (c) 2011 Couchbase, Inc, Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "DemoAppController.h"
#import "DemoQuery.h"
#import "MYURLHandler.h"
#import "Test.h"
#import "MYBlockUtils.h"
#import <Syncpoint/Syncpoint.h>

#undef FOR_TESTING_PURPOSES
#ifdef FOR_TESTING_PURPOSES
#import <TouchDBListener/TDListener.h>
@interface DemoAppController () <TDViewCompiler>
@end
static TDListener* sListener;
#endif


//#define kServerURLString @"http://single.couchbase.net/"
#define kServerURLString @"http://localhost:5984/"


#define kChangeGlowDuration 3.0


int main (int argc, const char * argv[]) {
    RunTestCases(argc,argv);
    return NSApplicationMain(argc, argv);
}


@implementation DemoAppController


@synthesize query = _query;


- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    [MYURLHandler installHandler];
}


- (void) applicationDidFinishLaunching: (NSNotification*)n {
    //gRESTLogLevel = kRESTLogRequestURLs;
    gCouchLogLevel = 1;
    
    NSDictionary* bundleInfo = [[NSBundle mainBundle] infoDictionary];
    NSString* dbName = [bundleInfo objectForKey: @"DemoDatabase"];
    if (!dbName) {
        NSLog(@"FATAL: Please specify a CouchDB database name in the app's Info.plist under the 'DemoDatabase' key");
        exit(1);
    }
    
    CouchTouchDBServer* server = [CouchTouchDBServer sharedInstance];
    NSAssert(!server.error, @"Error initializing TouchDB: %@", server.error);

    _database = [[server databaseNamed: dbName] retain];
    
    RESTOperation* op = [_database create];
    if (![op wait]) {
        NSAssert(op.error.code == 412, @"Error creating db: %@", op.error);
    }
    
    // Create a 'view' containing list items sorted by date:
    CouchDesignDocument* design = [_database designDocumentWithName: @"default"];
    [design defineViewNamed: @"byDate" mapBlock: MAPBLOCK({
        id date = [doc objectForKey: @"created_at"];
        if (date) emit(date, doc);
    }) version: @"1.0"];
    
    // and a validation function requiring parseable dates:
    design.validationBlock = VALIDATIONBLOCK({
        if ([newRevision objectForKey: @"_deleted"])
            return YES;
        id date = [newRevision objectForKey: @"created_at"];
        if (date && ! [RESTBody dateWithJSONObject: date]) {
            context.errorMessage = [@"invalid date " stringByAppendingString: date];
            return NO;
        }
        return YES;
    });
    
    // And why not a filter, just to allow some simple testing of filtered _changes.
    // For example, try curl 'http://localhost:8888/demo-shopping/_changes?filter=default/checked'
    [design defineFilterNamed: @"checked" block: FILTERBLOCK({
        return [[revision objectForKey: @"check"] boolValue];
    })];

    
    CouchQuery* q = [design queryViewNamed: @"byDate"];
    q.descending = YES;
    self.query = [[[DemoQuery alloc] initWithQuery: q] autorelease];
    self.query.modelClass =_tableController.objectClass;
    
    // Start up Syncpoint client:
    NSError* error;
    NSURL* remote = [NSURL URLWithString: kServerURLString];
    [SyncpointFacebookAuth setFacebookAppID: @"251541441584833"];
    _syncpoint = [[SyncpointClient alloc] initWithLocalServer: server
                                               remoteServer: remote
                                                      error: &error];
    if (!_syncpoint) {
        NSLog(@"Syncpoint failed to start: %@", error);
        exit(1);
    }
    [_syncpoint addObserver: self forKeyPath: @"state"
                    options: NSKeyValueObservingOptionOld context: NULL];
    if (_syncpoint.state == kSyncpointUnauthenticated)
        [_syncpoint authenticate: [SyncpointFacebookAuth new]];
    
    [self observeSync];
    
#ifdef FOR_TESTING_PURPOSES
    // Start a listener socket:
    sListener = [[TDListener alloc] initWithTDServer: server.touchServer port: 8888];
    [sListener start];

    // Register support for handling certain JS functions used in the CouchDB unit tests:
    [TDView setCompiler: self];
#endif
}


- (BOOL) openURL: (NSURL*)url error: (NSError**)outError {
    return [_syncpoint handleOpenURL: url];
}


#pragma mark - SYNC:


- (void) observeReplication: (CouchPersistentReplication*)repl {
    [repl addObserver: self forKeyPath: @"completed" options: 0 context: NULL];
    [repl addObserver: self forKeyPath: @"total" options: 0 context: NULL];
    [repl addObserver: self forKeyPath: @"error" options: 0 context: NULL];
    [repl addObserver: self forKeyPath: @"mode" options: 0 context: NULL];
}

- (void) stopObservingReplication: (CouchPersistentReplication*)repl {
    [repl removeObserver: self forKeyPath: @"completed"];
    [repl removeObserver: self forKeyPath: @"total"];
    [repl removeObserver: self forKeyPath: @"error"];
    [repl removeObserver: self forKeyPath: @"mode"];
}

- (void) forgetReplication: (CouchPersistentReplication**)repl {
    if (*repl) {
        [self stopObservingReplication: *repl];
        [*repl release];
        *repl = nil;
    }
}


- (void) observeSync {
    [self forgetReplication: &_pull];
    [self forgetReplication: &_push];
    
    NSURL* otherDbURL = nil;
    NSArray* repls = _database.replications;
    if (repls.count >= 2) {
        _pull = [[repls objectAtIndex: 0] retain];
        _push = [[repls objectAtIndex: 1] retain];
        [self observeReplication: _pull];
        [self observeReplication: _push];
        otherDbURL = _pull.remoteURL;
    }
    _syncHostField.stringValue = otherDbURL ? $sprintf(@"⇄ %@", otherDbURL.host) : @"";
}


- (void) updateSyncStatusView {
    int value;
    NSString* tooltip = nil;
    if (_pull.error) {
        value = 3;  // red
        tooltip = _pull.error.localizedDescription;
    } else if (_push.error) {
        value = 3;  // red
        tooltip = _push.error.localizedDescription;
    } else switch(MAX(_pull.mode, _push.mode)) {
        case kCouchReplicationStopped:
            value = 3; 
            tooltip = @"Sync stopped";
            break;  // red
        case kCouchReplicationOffline:
            value = 2;  // yellow
            tooltip = @"Offline";
            break;
        case kCouchReplicationIdle:
            value = 0;
            tooltip = @"Everything's in sync!";
            break;
        case kCouchReplicationActive:
            value = 1;
            tooltip = @"Syncing data...";
            break;
    }
    _syncStatusView.intValue = value;
    _syncStatusView.toolTip = tooltip;
}


- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object 
                         change:(NSDictionary *)change context:(void *)context
{
    if (object == _syncpoint) {
        if ([keyPath isEqualToString: @"state"]) {
            SyncpointState oldState = [[change objectForKey: NSKeyValueChangeOldKey] intValue];
            if (oldState < kSyncpointReady && _syncpoint.state == kSyncpointReady) {
                // Syncpoint is now ready -- subscribe if necessary:
                NSError* error;
                if (![_syncpoint.session installChannelNamed: @"grocery-sync"
                                                  toDatabase: _database
                                                       error: &error]) {
                    NSLog(@"Couldn't subscribe to channel: %@", error);
                    exit(1);
                }
                [self observeSync];
            }
        }
        return;
    }

    CouchPersistentReplication* repl = object;
    if ([keyPath isEqualToString: @"completed"] || [keyPath isEqualToString: @"total"]) {
        if (repl == _pull || repl == _push) {
            unsigned completed = _pull.completed + _push.completed;
            unsigned total = _pull.total + _push.total;
            NSLog(@"SYNC progress: %u / %u", completed, total);
            if (total > 0 && completed < total) {
                [_syncProgress setDoubleValue: (completed / (double)total)];
            } else {
                [_syncProgress setDoubleValue: 0.0];
            }
        }
    } else if ([keyPath isEqualToString: @"mode"]) {
        [self updateSyncStatusView];
    } else if ([keyPath isEqualToString: @"error"]) {
        [self updateSyncStatusView];
        if (repl.error) {
            NSAlert* alert = [NSAlert alertWithMessageText: @"Replication failed"
                                             defaultButton: nil
                                           alternateButton: nil
                                               otherButton: nil
                                 informativeTextWithFormat: @"Replication with %@ failed.\n\n %@",
                              repl.remoteURL, repl.error.localizedDescription];
            [alert beginSheetModalForWindow: _window
                              modalDelegate: nil didEndSelector: NULL contextInfo: NULL];
        }
    } else if ([keyPath isEqualToString: @"running"]) {
        if (repl != _push && repl != _pull) {
            // end of a 1-shot replication
            [self stopObservingReplication: repl];
        }
    }
}


#pragma mark - JS MAP/REDUCE FUNCTIONS:

#ifdef FOR_TESTING_PURPOSES

// These map/reduce functions are used in the CouchDB 'basics.js' unit tests. By recognizing them
// here and returning equivalent native blocks, we can run those tests.

- (TDMapBlock) compileMapFunction: (NSString*)mapSource language:(NSString *)language {
    if (![language isEqualToString: @"javascript"])
        return NULL;
    TDMapBlock mapBlock = NULL;
    if ([mapSource isEqualToString: @"(function (doc) {if (doc.a == 4) {emit(null, doc.b);}})"]) {
        mapBlock = ^(NSDictionary* doc, TDMapEmitBlock emit) {
            if ([[doc objectForKey: @"a"] isEqual: [NSNumber numberWithInt: 4]])
                emit(nil, [doc objectForKey: @"b"]);
        };
    } else if ([mapSource isEqualToString: @"(function (doc) {emit(doc.foo, null);})"] ||
               [mapSource isEqualToString: @"function(doc) { emit(doc.foo, null); }"]) {
        mapBlock = ^(NSDictionary* doc, TDMapEmitBlock emit) {
            emit([doc objectForKey: @"foo"], nil);
        };
    }
    return [[mapBlock copy] autorelease];
}


- (TDReduceBlock) compileReduceFunction: (NSString*)reduceSource language:(NSString *)language {
    if (![language isEqualToString: @"javascript"])
        return NULL;
    TDReduceBlock reduceBlock = NULL;
    if ([reduceSource isEqualToString: @"(function (keys, values) {return sum(values);})"]) {
        reduceBlock = ^(NSArray* keys, NSArray* values, BOOL rereduce) {
            return [TDView totalValues: values];
        };
    }
    return [[reduceBlock copy] autorelease];
}

#endif


#pragma mark HIGHLIGHTING NEW ITEMS:


- (void)tableView:(NSTableView *)tableView
  willDisplayCell:(id)cell
   forTableColumn:(NSTableColumn *)tableColumn
              row:(NSInteger)row 
{
    NSColor* bg = nil;

    NSArray* items = _tableController.arrangedObjects;
    if (row >= (NSInteger)items.count)
        return;                 // Don't know why I get called on illegal rows, but it happens...
    CouchModel* item = [items objectAtIndex: row];
    NSTimeInterval changedFor = item.timeSinceExternallyChanged;
    if (changedFor > 0 && changedFor < kChangeGlowDuration) {
        float fraction = (float)(1.0 - changedFor / kChangeGlowDuration);
        if (YES || [cell isKindOfClass: [NSButtonCell class]])
            bg = [[NSColor controlBackgroundColor] blendedColorWithFraction: fraction 
                                                        ofColor: [NSColor yellowColor]];
        else
            bg = [[NSColor yellowColor] colorWithAlphaComponent: fraction];
        
        if (!_glowing) {
            _glowing = YES;
            MYAfterDelay(0.1, ^{
                _glowing = NO;
                [_table setNeedsDisplay: YES];
            });
        }
    }
    
    [cell setBackgroundColor: bg];
    [cell setDrawsBackground: (bg != nil)];
}


@end
