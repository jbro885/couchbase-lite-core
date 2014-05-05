//
//  MapReduce_Tests.m
//  CBForest
//
//  Created by Jens Alfke on 4/7/14.
//  Copyright (c) 2014 Couchbase. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "CBForestMapReduceIndex.h"
#import "CBForestPrivate.h"
#import <libkern/OSAtomic.h>


#define kDBPath @"/tmp/temp.fdb"
#define kIndexPath @"/tmp/temp.fdbindex"


@interface MapReduce_Tests : XCTestCase
@end


@implementation MapReduce_Tests
{
    CBForestDB* db;
    CBForestMapReduceIndex* index;
}


- (void) setUp {
    NSError* error;
    [[NSFileManager defaultManager] removeItemAtPath: kDBPath error: &error];
    db = [[CBForestDB alloc] initWithFile: kDBPath options: kCBForestDBCreate config: nil error: &error];
    XCTAssert(db, @"Couldn't open db: %@", error);
    [[NSFileManager defaultManager] removeItemAtPath: kIndexPath error: &error];
    index = [[CBForestMapReduceIndex alloc] initWithFile: kIndexPath options: kCBForestDBCreate config: nil error: &error];
    XCTAssert(index, @"Couldn't open index: %@", error);
    index.sourceDatabase = db;
}

- (void) tearDown {
    [index close];
    index = nil;
    [db close];
    db = nil;
    [super tearDown];
}


- (void) writeJSONBody: (id)body ofDocumentID: (NSString*)docID {
    CBForestDocument* doc = [db makeDocumentWithID: docID];
    NSError* error;
    XCTAssert([doc writeBody: JSONToData(body,NULL) metadata: nil error: &error],
              @"Couldn't save doc '%@': %@", docID, error);
}


- (void) testMapReduce {
    // Populate the database:
    NSDictionary* data = @{
                           @"CA": @{@"name": @"California",
                                    @"cities":@[@"San Jose", @"San Francisco", @"Cambria"]},
                           @"WA": @{@"name": @"Washington",
                                    @"cities": @[@"Seattle", @"Port Townsend", @"Skookumchuk"]},
                           @"OR": @{@"name": @"Oregon",
                                    @"cities": @[@"Portland", @"Eugene"]}};
    for (NSString* docID in data) {
        [self writeJSONBody: data[docID] ofDocumentID: docID];
    }

    // Initialize the index:
    __block int32_t nMapCalls = 0;
    index.map = ^(CBForestDocument* doc, NSData* rawBody, CBForestIndexEmitBlock emit) {
        OSAtomicIncrement32(&nMapCalls);
        NSError* error;
        XCTAssert(rawBody, @"Couldn't read doc body: %@", error);
        NSDictionary* body = DataToJSON(rawBody, NULL);
        for (NSString* city in body[@"cities"])
            emit(city, body[@"name"]);
    };
    index.mapVersion = @"1";

    NSLog(@"--- Updating index");
    NSError* error;
    OSAtomicAnd32(0, (uint32_t*)&nMapCalls);
    XCTAssert([index updateIndex: &error], @"Updating index failed: %@", error);
    XCTAssertEqual(nMapCalls, 3);

    NSLog(@"--- First query");
    __block int nRows = 0;
    CBForestQueryEnumerator* e;
    e = [[CBForestQueryEnumerator alloc] initWithIndex: index
                                              startKey: nil startDocID: nil
                                                endKey: nil endDocID: nil
                                               options: NULL
                                                 error: &error];
    XCTAssert(e, @"Couldn't create query enumerator: %@", error);
    while (e.nextObject) {
        nRows++;
        NSLog(@"key = %@, value=%@, seq=%llu, docID = %@", e.key, e.value, e.sequence, e.docID);
    }
    XCTAssertEqual(nRows, 8);

    NSLog(@"--- Updating OR");
    [self writeJSONBody: @{@"name": @"Oregon",
                           @"cities": @[@"Portland", @"Walla Walla", @"Salem"]}
           ofDocumentID: @"OR"];
    OSAtomicAnd32(0, (uint32_t*)&nMapCalls);
    XCTAssert([index updateIndex: &error], @"Updating index failed: %@", error);
    XCTAssertEqual(nMapCalls, 1);

    NSLog(@"--- After updating OR");
    nRows = 0;
    e = [[CBForestQueryEnumerator alloc] initWithIndex: index
                                              startKey: nil startDocID: nil
                                                endKey: nil endDocID: nil
                                               options: NULL
                                                 error: &error];
    XCTAssert(e, @"Couldn't create query enumerator: %@", error);
    while (e.nextObject) {
          nRows++;
          NSLog(@"key = %@, value=%@, docID = %@, seq=%llu", e.key, e.value, e.docID, e.sequence);
    }
    XCTAssertEqual(nRows, 9);

    [self writeJSONBody: @{@"_deleted": @YES} ofDocumentID: @"CA"];
    OSAtomicAnd32(0, (uint32_t*)&nMapCalls);
    XCTAssert([index updateIndex: &error], @"Updating index failed: %@", error);
    XCTAssertEqual(nMapCalls, 1);

    NSLog(@"--- After removing CA:");
    nRows = 0;
    e = [[CBForestQueryEnumerator alloc] initWithIndex: index
                                              startKey: nil startDocID: nil
                                                endKey: nil endDocID: nil
                                               options: NULL
                                                 error: &error];
    XCTAssert(e, @"Couldn't create query enumerator: %@", error);
    while (e.nextObject) {
        nRows++;
        NSLog(@"key = %@, value=%@, docID = %@, seq = %llu", e.key, e.value, e.docID, e.sequence);
    }
    XCTAssertEqual(nRows, 6);
}


- (void) testBigMapReduce {
    NSLog(@"Writing documents...");
    const int kNumDocs = 10000;
    NSArray* colors = @[@"red", @"orange", @"yellow", @"green", @"blue", @"violet"];

    void (^addDocBlock)(size_t) = ^(size_t i) {
        NSDictionary* body = @{@"color": colors[random() % colors.count],
                               @"n": @(random())};
        NSString* docID = [NSString stringWithFormat: @"doc-%06d", (int)i];
        [self writeJSONBody: body ofDocumentID: docID];
    };

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [db inTransaction: ^BOOL {
#if 1
        dispatch_apply(kNumDocs, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                       addDocBlock);
#else
        for (size_t i=0; i<kNumDocs; i++)
            addDocBlock(i);
#endif
        return YES;
    }];
    NSLog(@"  ...writing docs took %.3f sec", (CFAbsoluteTimeGetCurrent()-start));

    index.map = ^(CBForestDocument* doc, NSData* rawBody, CBForestIndexEmitBlock emit) {
        NSDictionary* body = DataToJSON(rawBody, NULL);
        emit(body[@"color"], body[@"n"]);
        //usleep(1000);
    };
    index.mapVersion = @"1";

    NSLog(@"Updating index...");
    start = CFAbsoluteTimeGetCurrent();
    NSError* error;
    XCTAssert([index updateIndex: &error], @"Updating index failed: %@", error);
    NSLog(@"  ...updating index took %.3f sec", (CFAbsoluteTimeGetCurrent()-start));

    NSLog(@"Querying...");
    __block int nRows = 0;
    NSCountedSet* colorSet = [[NSCountedSet alloc] init];
    CBForestQueryEnumerator* e;
    e = [[CBForestQueryEnumerator alloc] initWithIndex: index
                                              startKey: nil startDocID: nil
                                                endKey: nil endDocID: nil
                                               options: NULL
                                                 error: &error];
    XCTAssert(e, @"Couldn't create query enumerator: %@", error);
    while (e.nextObject) {
        nRows++;
        [colorSet addObject: e.key];
        //NSLog(@"key = %@, value=%@, docID = %@, seq = %llu", key, value, docID, sequence);
    }
    XCTAssertEqual(nRows, kNumDocs);
    NSLog(@"Query completed: %@", colorSet);
}

- (void) testFullTextIndex {
    NSArray* text = @[@"I must not fear.",
                      @"Fear is the mind-killer.",
                      @"Fear is the little-death that brings total obliteration.",
                      @"I will face my fear.",
                      @"I will permit it to pass over me and through me.",
                      @"And when it has gone past I will turn the inner eye to see its path.",
                      @"Where the fear has gone there will be nothing....only I will remain."];
    int lineNo = 1;
    for (NSString* line in text)
        [self writeJSONBody: @{@"text": line}
               ofDocumentID: [NSString stringWithFormat: @"line-%d", lineNo++]];

    index.textTokenizer = [[CBTextTokenizer alloc] init];
    index.map = ^(CBForestDocument* doc, NSData* rawBody, CBForestIndexEmitBlock emit) {
        NSDictionary* body = DataToJSON(rawBody, NULL);
        emit(body[@"text"], nil);
    };
    index.mapVersion = @"1";

    NSError* error;
    XCTAssert([index updateIndex: &error], @"Updating index failed: %@", error);

    NSLog(@"View dump:\n%@", index.dump);

    // Query with a regular enumerator, looking at the keys/tokens:
    NSMutableArray* docs = [NSMutableArray array];
    CBForestQueryEnumerator* e;
    e = [[CBForestQueryEnumerator alloc] initWithIndex: index
                                              startKey: @"fear" startDocID: nil
                                                endKey: @"fear" endDocID: nil
                                               options: NULL
                                                 error: &error];
    XCTAssert(e, @"Couldn't create query enumerator: %@", error);
    int nRows = 0;
    while (e.nextObject) {
        nRows++;
        NSLog(@"key = %@, value=%@, docID = %@, seq = %llu", e.key, e.value, e.docID, e.sequence);
        XCTAssertEqualObjects(e.key, @"fear");
        [docs addObject: e.docID];
    }
    XCTAssertEqualObjects(docs, (@[@"line-1", @"line-2", @"line-3", @"line-4", @"line-7"]));

    // Query with the special multi-word enumerator:
    CBForestQueryMultiKeyEnumerator* ie;
    ie = [[CBForestQueryMultiKeyEnumerator alloc] initWithIndex: index
                                                           keys: @[@"fear", @"face"]
                                                   intersection: YES
                                                          error: &error];
    XCTAssert(ie, @"Couldn't create query enumerator: %@", error);
    XCTAssertEqualObjects(ie.allObjects, @[@"line-4"]);

    // Query with -enumerateDocsContainingWords:
    NSEnumerator* ee = [index enumerateDocsContainingWords: @"the fears bring" all: YES error: &error];
    XCTAssert(ee, @"Couldn't create word enumerator: %@", error);
    docs = [NSMutableArray array];
    for (CBForestDocument* doc in ee)
        [docs addObject: doc];
    XCTAssertEqualObjects(docs, (@[@"line-3"]));

    ee = [index enumerateDocsContainingWords: @"pas*" all: YES error: &error];
    XCTAssert(ee, @"Couldn't create word enumerator: %@", error);
    docs = [NSMutableArray array];
    for (CBForestDocument* doc in ee)
        [docs addObject: doc];
    XCTAssertEqualObjects(docs, (@[@"line-5", @"line-6"]));
}

@end
