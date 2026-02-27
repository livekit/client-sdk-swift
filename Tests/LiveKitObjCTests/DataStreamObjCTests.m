/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Cross-ref: Tests/LiveKitCoreTests/DataStream/DataStreamTests.swift

@import XCTest;
@import LiveKit;
@import LiveKitTestSupport;

@interface DataStreamObjCTests : XCTestCase <RoomDelegate>
@property (nonatomic, strong) XCTestExpectation *participantJoinedExp;
@end

@implementation DataStreamObjCTests

- (void)room:(Room *)room participantDidConnect:(RemoteParticipant *)participant {
    [self.participantJoinedExp fulfill];
}

#pragma mark - Tests

- (void)testSendText {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;

    // Room0: subscriber
    NSString *token0 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"text-recv"
                                                        canPublish:NO
                                                    canPublishData:NO
                                                      canSubscribe:YES
                                                             error:&error];
    XCTAssertNil(error);

    // Room1: publisher
    NSString *token1 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"text-send"
                                                        canPublish:NO
                                                    canPublishData:YES
                                                      canSubscribe:NO
                                                             error:&error];
    XCTAssertNil(error);

    Room *room0 = [[Room alloc] initWithDelegate:self connectOptions:nil roomOptions:nil];
    Room *room1 = [[Room alloc] initWithDelegate:nil connectOptions:nil roomOptions:nil];

    // Connect room0
    XCTestExpectation *connect0 = [self expectationWithDescription:@"connect0"];
    [room0 connectWithUrl:url token:token0 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect0 fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    // Set up participant join expectation
    self.participantJoinedExp = [self expectationWithDescription:@"participantJoined"];

    // Connect room1
    XCTestExpectation *connect1 = [self expectationWithDescription:@"connect1"];
    [room1 connectWithUrl:url token:token1 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect1 fulfill];
    }];
    [self waitForExpectations:@[connect1, self.participantJoinedExp] timeout:30];

    // Register text stream handler on room0
    __block TextStreamReader *receivedReader = nil;
    XCTestExpectation *receivedStreamExp = [self expectationWithDescription:@"receivedStream"];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [room0 registerTextStreamHandlerFor:@"test-text" onNewStream:^(TextStreamReader *reader, ParticipantIdentity *identity) {
        receivedReader = reader;
        [receivedStreamExp fulfill];
    } onError:nil];
#pragma clang diagnostic pop

    // Brief pause for handler registration to complete
    [NSThread sleepForTimeInterval:1.0];

    // Send text from room1
    StreamTextOptions *options = [[StreamTextOptions alloc] initWithTopic:@"test-text"
                                                              attributes:@{}
                                                    destinationIdentities:@[]
                                                                      id:nil
                                                                 version:0
                                                       attachedStreamIDs:@[]
                                                         replyToStreamID:nil];
    XCTestExpectation *sendExp = [self expectationWithDescription:@"textSent"];

    [room1.localParticipant sendText:@"Hello from ObjC" options:options completionHandler:^(TextStreamInfo *info, NSError *err) {
        XCTAssertNil(err);
        XCTAssertNotNil(info);
        [sendExp fulfill];
    }];

    [self waitForExpectations:@[receivedStreamExp, sendExp] timeout:30];

    // Read received text
    XCTAssertNotNil(receivedReader);
    __block NSMutableString *receivedText = [NSMutableString string];
    XCTestExpectation *readExp = [self expectationWithDescription:@"readComplete"];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [receivedReader readChunksOnChunk:^(NSString *chunk) {
        [receivedText appendString:chunk];
    } onCompletion:^(NSError *err) {
        XCTAssertNil(err);
        [readExp fulfill];
    }];
#pragma clang diagnostic pop

    [self waitForExpectationsWithTimeout:30 handler:nil];

    XCTAssertEqualObjects(receivedText, @"Hello from ObjC");

    // Unregister text stream handler (auto-generated completionHandler variant)
    XCTestExpectation *unregisterExp = [self expectationWithDescription:@"unregisterText"];
    [room0 unregisterTextStreamHandlerFor:@"test-text" completionHandler:^{
        [unregisterExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];

    // Disconnect
    XCTestExpectation *disconnect0 = [self expectationWithDescription:@"disconnect0"];
    XCTestExpectation *disconnect1 = [self expectationWithDescription:@"disconnect1"];
    [room0 disconnectWithCompletionHandler:^{ [disconnect0 fulfill]; }];
    [room1 disconnectWithCompletionHandler:^{ [disconnect1 fulfill]; }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

- (void)testStreamText {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;

    NSString *token0 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"stream-recv"
                                                        canPublish:NO
                                                    canPublishData:NO
                                                      canSubscribe:YES
                                                             error:&error];
    XCTAssertNil(error);

    NSString *token1 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"stream-send"
                                                        canPublish:NO
                                                    canPublishData:YES
                                                      canSubscribe:NO
                                                             error:&error];
    XCTAssertNil(error);

    Room *room0 = [[Room alloc] initWithDelegate:self connectOptions:nil roomOptions:nil];
    Room *room1 = [[Room alloc] initWithDelegate:nil connectOptions:nil roomOptions:nil];

    // Connect both rooms
    XCTestExpectation *connect0 = [self expectationWithDescription:@"connect0"];
    [room0 connectWithUrl:url token:token0 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect0 fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    self.participantJoinedExp = [self expectationWithDescription:@"participantJoined"];

    XCTestExpectation *connect1 = [self expectationWithDescription:@"connect1"];
    [room1 connectWithUrl:url token:token1 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect1 fulfill];
    }];
    [self waitForExpectations:@[connect1, self.participantJoinedExp] timeout:30];

    // Register text handler on room0
    __block NSMutableString *receivedText = [NSMutableString string];
    XCTestExpectation *readCompleteExp = [self expectationWithDescription:@"readComplete"];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [room0 registerTextStreamHandlerFor:@"stream-text" onNewStream:^(TextStreamReader *reader, ParticipantIdentity *identity) {
        // Read all chunks from the reader
        [reader readChunksOnChunk:^(NSString *chunk) {
            [receivedText appendString:chunk];
        } onCompletion:^(NSError *err) {
            XCTAssertNil(err);
            [readCompleteExp fulfill];
        }];
    } onError:nil];
#pragma clang diagnostic pop

    [NSThread sleepForTimeInterval:1.0];

    // Stream text from room1 using auto-generated completion handler variant
    StreamTextOptions *options = [[StreamTextOptions alloc] initWithTopic:@"stream-text"
                                                              attributes:@{}
                                                    destinationIdentities:@[]
                                                                      id:nil
                                                                 version:0
                                                       attachedStreamIDs:@[]
                                                         replyToStreamID:nil];

    [room1.localParticipant streamTextWithOptions:options completionHandler:^(TextStreamWriter *writer, NSError *err) {
        XCTAssertNil(err);
        XCTAssertNotNil(writer);
        // Use auto-bridged async methods (completion handler variants) for ordered writes
        [writer write:@"Hello " completionHandler:^(NSError *err1) {
            XCTAssertNil(err1);
            [writer write:@"World" completionHandler:^(NSError *err2) {
                XCTAssertNil(err2);
                [writer closeWithReason:nil completionHandler:^(NSError *err3) {
                    XCTAssertNil(err3);
                }];
            }];
        }];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];

    XCTAssertEqualObjects(receivedText, @"Hello World");

    // Disconnect
    XCTestExpectation *disconnect0 = [self expectationWithDescription:@"disconnect0"];
    XCTestExpectation *disconnect1 = [self expectationWithDescription:@"disconnect1"];
    [room0 disconnectWithCompletionHandler:^{ [disconnect0 fulfill]; }];
    [room1 disconnectWithCompletionHandler:^{ [disconnect1 fulfill]; }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

- (void)testSendFile {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;

    NSString *token0 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"file-recv"
                                                        canPublish:NO
                                                    canPublishData:NO
                                                      canSubscribe:YES
                                                             error:&error];
    XCTAssertNil(error);

    NSString *token1 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"file-send"
                                                        canPublish:NO
                                                    canPublishData:YES
                                                      canSubscribe:NO
                                                             error:&error];
    XCTAssertNil(error);

    Room *room0 = [[Room alloc] initWithDelegate:self connectOptions:nil roomOptions:nil];
    Room *room1 = [[Room alloc] initWithDelegate:nil connectOptions:nil roomOptions:nil];

    // Connect both rooms
    XCTestExpectation *connect0 = [self expectationWithDescription:@"connect0"];
    [room0 connectWithUrl:url token:token0 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect0 fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    self.participantJoinedExp = [self expectationWithDescription:@"participantJoined"];

    XCTestExpectation *connect1 = [self expectationWithDescription:@"connect1"];
    [room1 connectWithUrl:url token:token1 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect1 fulfill];
    }];
    [self waitForExpectations:@[connect1, self.participantJoinedExp] timeout:30];

    // Create temp file with test data
    NSData *testData = [@"Test file content for ObjC" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"objc_test_file.txt"];
    [testData writeToFile:tempPath atomically:YES];
    NSURL *fileURL = [NSURL fileURLWithPath:tempPath];

    // Register byte stream handler on room0
    __block NSMutableData *receivedData = [NSMutableData data];
    __block ByteStreamInfo *receivedInfo = nil;
    XCTestExpectation *readCompleteExp = [self expectationWithDescription:@"readComplete"];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [room0 registerByteStreamHandlerFor:@"test-file" onNewStream:^(ByteStreamReader *reader, ParticipantIdentity *identity) {
        receivedInfo = reader.info;
        [reader readChunksOnChunk:^(NSData *chunk) {
            [receivedData appendData:chunk];
        } onCompletion:^(NSError *err) {
            XCTAssertNil(err);
            [readCompleteExp fulfill];
        }];
    } onError:nil];
#pragma clang diagnostic pop

    [NSThread sleepForTimeInterval:1.0];

    // Send file from room1
    StreamByteOptions *options = [[StreamByteOptions alloc] initWithTopic:@"test-file"
                                                              attributes:@{}
                                                    destinationIdentities:@[]
                                                                      id:nil
                                                                mimeType:@"text/plain"
                                                                    name:@"objc_test_file.txt"
                                                               totalSizeNumber:nil];
    XCTestExpectation *sendExp = [self expectationWithDescription:@"fileSent"];

    [room1.localParticipant sendFile:fileURL options:options completionHandler:^(ByteStreamInfo *info, NSError *err) {
        XCTAssertNil(err);
        XCTAssertNotNil(info);
        [sendExp fulfill];
    }];

    [self waitForExpectations:@[readCompleteExp, sendExp] timeout:30];

    // Verify received data matches
    XCTAssertEqualObjects(receivedData, testData);
    XCTAssertNotNil(receivedInfo);
    XCTAssertEqualObjects(receivedInfo.topic, @"test-file");

    // Clean up temp file
    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

    // Unregister byte stream handler (auto-generated completionHandler variant)
    XCTestExpectation *unregisterExp = [self expectationWithDescription:@"unregisterBytes"];
    [room0 unregisterByteStreamHandlerFor:@"test-file" completionHandler:^{
        [unregisterExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];

    // Disconnect
    XCTestExpectation *disconnect0 = [self expectationWithDescription:@"disconnect0"];
    XCTestExpectation *disconnect1 = [self expectationWithDescription:@"disconnect1"];
    [room0 disconnectWithCompletionHandler:^{ [disconnect0 fulfill]; }];
    [room1 disconnectWithCompletionHandler:^{ [disconnect1 fulfill]; }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

- (void)testStreamBytes {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;

    NSString *token0 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"bytes-recv"
                                                        canPublish:NO
                                                    canPublishData:NO
                                                      canSubscribe:YES
                                                             error:&error];
    XCTAssertNil(error);

    NSString *token1 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"bytes-send"
                                                        canPublish:NO
                                                    canPublishData:YES
                                                      canSubscribe:NO
                                                             error:&error];
    XCTAssertNil(error);

    Room *room0 = [[Room alloc] initWithDelegate:self connectOptions:nil roomOptions:nil];
    Room *room1 = [[Room alloc] initWithDelegate:nil connectOptions:nil roomOptions:nil];

    // Connect both rooms
    XCTestExpectation *connect0 = [self expectationWithDescription:@"connect0"];
    [room0 connectWithUrl:url token:token0 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect0 fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    self.participantJoinedExp = [self expectationWithDescription:@"participantJoined"];

    XCTestExpectation *connect1 = [self expectationWithDescription:@"connect1"];
    [room1 connectWithUrl:url token:token1 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect1 fulfill];
    }];
    [self waitForExpectations:@[connect1, self.participantJoinedExp] timeout:30];

    // Register byte stream handler on room0
    __block NSMutableData *receivedData = [NSMutableData data];
    XCTestExpectation *readCompleteExp = [self expectationWithDescription:@"readComplete"];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [room0 registerByteStreamHandlerFor:@"stream-bytes" onNewStream:^(ByteStreamReader *reader, ParticipantIdentity *identity) {
        [reader readChunksOnChunk:^(NSData *chunk) {
            [receivedData appendData:chunk];
        } onCompletion:^(NSError *err) {
            XCTAssertNil(err);
            [readCompleteExp fulfill];
        }];
    } onError:nil];
#pragma clang diagnostic pop

    [NSThread sleepForTimeInterval:1.0];

    // Stream bytes from room1 using auto-generated completionHandler variant
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    StreamByteOptions *options = [[StreamByteOptions alloc] initWithTopic:@"stream-bytes"
                                                              attributes:@{}
                                                    destinationIdentities:@[]
                                                                      id:nil
                                                                mimeType:@"application/octet-stream"
                                                                    name:nil
                                                               totalSizeNumber:nil];
#pragma clang diagnostic pop

    NSData *chunk1 = [@"Hello " dataUsingEncoding:NSUTF8StringEncoding];
    NSData *chunk2 = [@"Bytes" dataUsingEncoding:NSUTF8StringEncoding];

    [room1.localParticipant streamBytesWithOptions:options completionHandler:^(ByteStreamWriter *writer, NSError *err) {
        XCTAssertNil(err);
        XCTAssertNotNil(writer);
        [writer write:chunk1 completionHandler:^(NSError *err1) {
            XCTAssertNil(err1);
            [writer write:chunk2 completionHandler:^(NSError *err2) {
                XCTAssertNil(err2);
                [writer closeWithReason:nil completionHandler:^(NSError *err3) {
                    XCTAssertNil(err3);
                }];
            }];
        }];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];

    NSData *expected = [@"Hello Bytes" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects(receivedData, expected);

    // Disconnect
    XCTestExpectation *disconnect0 = [self expectationWithDescription:@"disconnect0"];
    XCTestExpectation *disconnect1 = [self expectationWithDescription:@"disconnect1"];
    [room0 disconnectWithCompletionHandler:^{ [disconnect0 fulfill]; }];
    [room1 disconnectWithCompletionHandler:^{ [disconnect1 fulfill]; }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

@end
