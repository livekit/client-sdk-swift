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

// Cross-ref: Tests/LiveKitCoreTests/DataTrack/DataTrackTests.swift
// Proves the public data track API is usable from Objective-C: publish, push frames, query,
// unpublish (local), plus subscribe and receive frames (remote).

@import XCTest;
@import LiveKit;
@import LiveKitTestSupport;

@interface DataTrackObjCTests : XCTestCase <RoomDelegate>
@property (nonatomic, strong) XCTestExpectation *trackPublishedExp;
@property (nonatomic, strong) RemoteDataTrack *receivedTrack;
@end

@implementation DataTrackObjCTests

- (void)room:(Room *)room remoteParticipant:(RemoteParticipant *)participant didPublishDataTrack:(RemoteDataTrack *)track {
    self.receivedTrack = track;
    [self.trackPublishedExp fulfill];
}

- (void)testPublishSendReceiveQueryUnpublish {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;

    // Subscriber room.
    NSString *subToken = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                            identity:@"dt-recv"
                                                          canPublish:NO
                                                      canPublishData:NO
                                                        canSubscribe:YES
                                                               error:&error];
    XCTAssertNil(error);

    // Publisher room.
    NSString *pubToken = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                            identity:@"dt-send"
                                                          canPublish:NO
                                                      canPublishData:YES
                                                        canSubscribe:NO
                                                               error:&error];
    XCTAssertNil(error);

    Room *subRoom = [[Room alloc] initWithDelegate:self connectOptions:nil roomOptions:nil];
    Room *pubRoom = [[Room alloc] initWithDelegate:nil connectOptions:nil roomOptions:nil];

    // Connect both rooms.
    XCTestExpectation *connectSub = [self expectationWithDescription:@"connectSub"];
    [LKObjCRoomHelper connectWithRoom:subRoom url:url token:subToken completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connectSub fulfill];
    }];
    XCTestExpectation *connectPub = [self expectationWithDescription:@"connectPub"];
    [LKObjCRoomHelper connectWithRoom:pubRoom url:url token:pubToken completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connectPub fulfill];
    }];
    [self waitForExpectations:@[connectSub, connectPub] timeout:30];

    // Publish a data track with frame metadata; the subscriber's delegate should observe it.
    self.trackPublishedExp = [self expectationWithDescription:@"trackPublished"];
    XCTestExpectation *publishExp = [self expectationWithDescription:@"publish"];
    __block LocalDataTrack *localTrack = nil;
    DataTrackSchemaId *schema = [[DataTrackSchemaId alloc] initWithName:@"objc-schema" encoding:@"jsonschema"];
    DataTrackPublishOptions *publishOptions = [[DataTrackPublishOptions alloc] initWithSchema:schema frameEncoding:@"json"];
    [pubRoom.localParticipant publishDataTrackWithName:@"objc-dt" options:publishOptions completionHandler:^(LocalDataTrack *track, NSError *err) {
        XCTAssertNil(err);
        XCTAssertNotNil(track);
        XCTAssertTrue(track.isPublished);
        localTrack = track;
        [publishExp fulfill];
    }];
    [self waitForExpectations:@[publishExp, self.trackPublishedExp] timeout:30];

    XCTAssertNotNil(self.receivedTrack);
    XCTAssertEqualObjects(self.receivedTrack.info.name, @"objc-dt");

    // Subscribe and receive frames.
    XCTestExpectation *subscribeExp = [self expectationWithDescription:@"subscribe"];
    __block DataTrackStream *stream = nil;
    [self.receivedTrack subscribeWithBufferSize:16 completionHandler:^(DataTrackStream *s, NSError *err) {
        XCTAssertNil(err);
        XCTAssertNotNil(s);
        stream = s;
        [subscribeExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    // Brief pause for the subscription to be established on the SFU.
    [NSThread sleepForTimeInterval:1.0];

    NSData *payload = [@"hello-from-objc" dataUsingEncoding:NSUTF8StringEncoding];
    XCTestExpectation *receivedFrameExp = [self expectationWithDescription:@"receivedFrame"];
    receivedFrameExp.assertForOverFulfill = NO;
    [stream readOnFrame:^(DataTrackFrame *frame) {
        if ([frame.payload isEqualToData:payload]) {
            [receivedFrameExp fulfill];
        }
    } completionHandler:^{}];

    // Push frames from the publisher.
    for (int i = 0; i < 10; i++) {
        NSError *pushErr = nil;
        [localTrack tryPushWithFrame:[DataTrackFrame nowWithPayload:payload] error:&pushErr];
        XCTAssertNil(pushErr);
    }
    [self waitForExpectations:@[receivedFrameExp] timeout:30];

    // Unpublish.
    [localTrack unpublish];
    XCTestExpectation *unpublishExp = [self expectationWithDescription:@"unpublish"];
    [localTrack waitForUnpublishWithCompletionHandler:^{
        XCTAssertFalse(localTrack.isPublished);
        [unpublishExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];

    // Disconnect.
    XCTestExpectation *disconnectSub = [self expectationWithDescription:@"disconnectSub"];
    XCTestExpectation *disconnectPub = [self expectationWithDescription:@"disconnectPub"];
    [subRoom disconnectWithCompletionHandler:^{ [disconnectSub fulfill]; }];
    [pubRoom disconnectWithCompletionHandler:^{ [disconnectPub fulfill]; }];
    [self waitForExpectations:@[disconnectSub, disconnectPub] timeout:10];
}

@end
