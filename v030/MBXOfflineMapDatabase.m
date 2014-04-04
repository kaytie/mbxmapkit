//
//  MBXOfflineMapDatabase.m
//  MBXMapKit
//
//  Created by Will Snook on 3/17/14.
//  Copyright (c) 2014 MapBox. All rights reserved.
//

#import <sqlite3.h>
#import "MBXOfflineMapDatabase.h"
#import "MBXError.h"

#pragma mark -

@interface MBXOfflineMapDatabase ()

@property (readwrite, nonatomic) NSString *mapID;
@property (readwrite, nonatomic) BOOL metadata;
@property (readwrite, nonatomic) BOOL markers;
@property (readwrite, nonatomic) MBXRasterImageQuality imageQuality;
@property (readwrite, nonatomic) MKCoordinateRegion mapRegion;
@property (readwrite, nonatomic) NSInteger minimumZ;
@property (readwrite, nonatomic) NSInteger maximumZ;

@property (nonatomic) NSString *path;

@property (nonatomic) BOOL initializedProperly;

@end


#pragma mark -

@implementation MBXOfflineMapDatabase

- (id)initWithContentsOfFile:(NSString *)path
{
    self = [super init];

    if(self)
    {
        _path = path;

        NSString *mapID = [self sqliteMetadataForName:@"mapID"];
        NSString *metadata = [self sqliteMetadataForName:@"metadata"];
        NSString *markers = [self sqliteMetadataForName:@"markers"];
        NSString *imageQuality = [self sqliteMetadataForName:@"imageQuality"];
        NSString *region_latitude = [self sqliteMetadataForName:@"region_latitude"];
        NSString *region_longitude = [self sqliteMetadataForName:@"region_longitude"];
        NSString *region_latitude_delta = [self sqliteMetadataForName:@"region_latitude_delta"];
        NSString *region_longitude_delta = [self sqliteMetadataForName:@"region_longitude_delta"];
        NSString *minimumZ = [self sqliteMetadataForName:@"minimumZ"];
        NSString *maximumZ = [self sqliteMetadataForName:@"maximumZ"];

        if (mapID &&  metadata && markers && imageQuality
            && region_latitude && region_longitude && region_latitude_delta && region_longitude_delta
            && minimumZ && maximumZ
            )
        {
            // Reaching this point means that the specified database file at <path> pointed to an sqlite file which had all the
            // required correct values in its metadata table. That means the file passed the test for being a valid
            // offline map database.
            //
            _mapID = mapID;
            _metadata = [metadata boolValue];
            _markers =  [markers boolValue];

            _imageQuality = (MBXRasterImageQuality)[imageQuality integerValue];

            _mapRegion.center.latitude =     [region_latitude doubleValue];
            _mapRegion.center.longitude =    [region_longitude doubleValue];
            _mapRegion.span.latitudeDelta =  [region_latitude_delta doubleValue];
            _mapRegion.span.longitudeDelta = [region_longitude_delta doubleValue];

            _minimumZ = [minimumZ integerValue];
            _maximumZ = [maximumZ integerValue];

            _initializedProperly = YES;
        }
        else
        {
            // Reaching this point means the file at <path> isn't a valid offline map database, so we can't use it.
            //
            self = nil;
        }
    }

    return self;
}


- (NSData *)dataForURL:(NSURL *)url withError:(NSError **)error
{
    // If this assert fails, you may have tried to do something like [[MBXOfflineMapDatabase alloc] init]. Please don't do that!
    // The correct approach is to enumerate the [[MBXOfflineMapDownloader sharedOfflineMapDownloader].offlineMapDatabases array property
    // or to use the database provided by MBXOfflineMapDownloaderDelegate's -offlineMapDownloader:didCompleteOfflineMapDatabase:withError:.
    // Also, the offlineMaps array will only have map databases in it once you have completed downloading at least one offline map region.
    //
    assert(_initializedProperly);

    NSData *data = [self sqliteDataForURL:url];
    if(*error != NULL)
    {
        NSString *reason = [NSString stringWithFormat:@"The offline database has no data for %@",[url absoluteString]];
        *error = [MBXError errorWithCode:MBXMapKitErrorOfflineMapHasNoDataForKey reason:reason description:@"No offline data for key error"];
    }
    return data;
}


#pragma mark - sqlite stuff

- (NSString *)sqliteMetadataForName:(NSString *)name
{
    NSString *query = [NSString stringWithFormat:@"SELECT value FROM metadata WHERE name='%@';",name];
    NSData *data = [self sqliteDataForSingleColumnQuery:query];
    return data ? [[NSString alloc] initWithBytes:data.bytes length:data.length encoding:NSUTF8StringEncoding] : nil;
}


- (NSData *)sqliteDataForURL:(NSURL *)url
{
    NSString *query = [NSString stringWithFormat:@"select data from resources where url = \"%@\";", [url absoluteString]];
    NSData *data = [self sqliteDataForSingleColumnQuery:query];
    return data;
}


- (NSData *)sqliteDataForSingleColumnQuery:(NSString *)query
{
    // MBXMapKit expects libsqlite to have been compiled with SQLITE_THREADSAFE=2 (multi-thread mode), which means
    // that it can handle its own thread safety as long as you don't attempt to re-use database connections.
    // Since the queries here are all SELECT's, locking for writes shouldn't be an issue.
    // Some relevant sqlite documentation:
    // - http://sqlite.org/faq.html#q5
    // - http://www.sqlite.org/threadsafe.html
    // - http://www.sqlite.org/c3ref/threadsafe.html
    // - http://www.sqlite.org/c3ref/c_config_covering_index_scan.html#sqliteconfigmultithread
    //
    assert(sqlite3_threadsafe()==2);

    // Open the database read-only and multi-threaded. The slightly obscure c-style variable names here and below are
    // used to stay consistent with the sqlite documentaion. See http://sqlite.org/c3ref/open.html
    sqlite3 *db;
    int rc;
    const char *filename = [_path cStringUsingEncoding:NSUTF8StringEncoding];
    rc = sqlite3_open_v2(filename, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL);
    if (rc)
    {
        NSLog(@"Can't open database %@: %s", _path, sqlite3_errmsg(db));
        sqlite3_close(db);
        return nil;
    }

    // Prepare the query, see http://sqlite.org/c3ref/prepare.html
    const char *zSql = [query cStringUsingEncoding:NSUTF8StringEncoding];
    int nByte = (int)[query lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    sqlite3_stmt *ppStmt;
    const char *pzTail;
    rc = sqlite3_prepare_v2(db, zSql, nByte, &ppStmt, &pzTail);
    if (rc)
    {
        NSLog(@"Problem preparing sql statement: %s", sqlite3_errmsg(db));
        sqlite3_finalize(ppStmt);
        sqlite3_close(db);
        return nil;
    }

    // Evaluate the query, see http://sqlite.org/c3ref/step.html and http://sqlite.org/c3ref/column_blob.html
    NSData *data = nil;
    rc = sqlite3_step(ppStmt);
    if (rc == SQLITE_ROW)
    {
        // The query is supposed to be for exactly one column
        assert(sqlite3_column_count(ppStmt)==1);

        // Success!
        data = [NSData dataWithBytes:sqlite3_column_blob(ppStmt, 0) length:sqlite3_column_bytes(ppStmt, 0)];

        // Check if any more rows match
        if(sqlite3_step(ppStmt) != SQLITE_DONE)
        {
            // Oops, the query apparently matched more than one row (could also be an error)... not fatal, but not good.
            NSLog(@"Warning, query may match more than one row: %@",query);
        }
    }
    else if (rc == SQLITE_DONE)
    {
        // The query returned no results.
    }
    else if (rc == SQLITE_BUSY)
    {
        // This is bad, but theoretically it should never happen
        NSLog(@"sqlite3_step() returned SQLITE_BUSY. You probably have a concurrency problem.");
    }
    else
    {
        NSLog(@"sqlite3_step() produced an error: %s", sqlite3_errmsg(db));
    }

    // Clean up
    sqlite3_finalize(ppStmt);
    sqlite3_close(db);
    return data;
}

@end
