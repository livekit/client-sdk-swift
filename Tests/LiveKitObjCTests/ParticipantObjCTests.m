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

// Cross-ref: Tests/LiveKitCoreTests/ParticipantTests.swift

@import XCTest;
@import LiveKit;
@import LiveKitTestSupport;

@interface ParticipantObjCTests : XCTestCase <RoomDelegate>
@property (nonatomic, strong) XCTestExpectation *participantJoinedExp;
@end

@implementation ParticipantObjCTests

- (void)room:(Room *)room participantDidConnect:(RemoteParticipant *)participant {
    [self.participantJoinedExp fulfill];
}

- (void)testRemoteParticipants {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;

    NSString *token1 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"participant-1"
                                                        canPublish:NO
                                                    canPublishData:NO
                                                      canSubscribe:NO
                                                             error:&error];
    XCTAssertNil(error);

    NSString *token2 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"participant-2"
                                                        canPublish:NO
                                                    canPublishData:NO
                                                      canSubscribe:NO
                                                             error:&error];
    XCTAssertNil(error);

    // Room 1
    Room *room1 = [[Room alloc] initWithDelegate:self connectOptions:nil roomOptions:nil];

    XCTestExpectation *connect1 = [self expectationWithDescription:@"connect1"];
    [room1 connectWithUrl:url token:token1 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect1 fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    // Set up expectation for participant join
    self.participantJoinedExp = [self expectationWithDescription:@"participantJoined"];

    // Room 2
    Room *room2 = [[Room alloc] initWithDelegate:nil connectOptions:nil roomOptions:nil];

    XCTestExpectation *connect2 = [self expectationWithDescription:@"connect2"];
    [room2 connectWithUrl:url token:token2 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect2 fulfill];
    }];
    [self waitForExpectations:@[connect2, self.participantJoinedExp] timeout:30];

    XCTAssertEqual(room1.remoteParticipants.count, (NSUInteger)1);

    // Disconnect
    XCTestExpectation *disconnect1 = [self expectationWithDescription:@"disconnect1"];
    XCTestExpectation *disconnect2 = [self expectationWithDescription:@"disconnect2"];
    [room1 disconnectWithCompletionHandler:^{ [disconnect1 fulfill]; }];
    [room2 disconnectWithCompletionHandler:^{ [disconnect2 fulfill]; }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

- (void)testParticipantProperties {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;
    NSString *token = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                         identity:@"props-test"
                                                       canPublish:NO
                                                   canPublishData:NO
                                                     canSubscribe:NO
                                                            error:&error];
    XCTAssertNil(error);

    Room *room = [[Room alloc] initWithDelegate:nil connectOptions:nil roomOptions:nil];

    XCTestExpectation *connectExp = [self expectationWithDescription:@"connect"];
    [room connectWithUrl:url token:token connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connectExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    LocalParticipant *local = room.localParticipant;
    XCTAssertNotNil(local);

    // Access all public properties
    XCTAssertNotNil(local.sid);
    XCTAssertNotNil(local.identity);
    XCTAssertNotNil(local.name);
    XCTAssertNotNil(local.attributes);
    XCTAssertFalse(local.isSpeaking);
    XCTAssertNotNil(local.permissions);
    XCTAssertNotNil(local.trackPublications);
    XCTAssertNotNil(local.audioTracks);
    XCTAssertNotNil(local.videoTracks);

    // Disconnect
    XCTestExpectation *disconnectExp = [self expectationWithDescription:@"disconnect"];
    [room disconnectWithCompletionHandler:^{ [disconnectExp fulfill]; }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

- (void)testParticipantIdentity {
    ParticipantIdentity *identity = [[ParticipantIdentity alloc] initFrom:@"test-identity"];
    XCTAssertNotNil(identity);
    XCTAssertEqualObjects(identity.stringValue, @"test-identity");

    ParticipantIdentity *same = [[ParticipantIdentity alloc] initFrom:@"test-identity"];
    XCTAssertEqualObjects(identity, same);
    XCTAssertEqual(identity.hash, same.hash);

    ParticipantIdentity *different = [[ParticipantIdentity alloc] initFrom:@"other"];
    XCTAssertNotEqualObjects(identity, different);
}

@end
