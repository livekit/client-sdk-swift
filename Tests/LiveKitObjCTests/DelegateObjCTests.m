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

// Cross-ref: Tests/LiveKitCoreTests/Room/RoomTests.swift (testParticipantCleanUp)

@import XCTest;
@import LiveKit;
@import LiveKitTestSupport;

@interface DelegateObjCTests : XCTestCase <RoomDelegate>
@property (nonatomic, strong) XCTestExpectation *roomDidConnectExp;
@property (nonatomic, strong) XCTestExpectation *roomDidDisconnectExp;
@property (nonatomic, strong) XCTestExpectation *participantDidConnectExp;
@property (nonatomic, strong) XCTestExpectation *participantDidDisconnectExp;
@property (nonatomic, strong) RemoteParticipant *connectedParticipant;
@property (nonatomic, strong) RemoteParticipant *disconnectedParticipant;
@end

@implementation DelegateObjCTests

// MARK: - RoomDelegate

- (void)roomDidConnect:(Room *)room {
    [self.roomDidConnectExp fulfill];
}

- (void)room:(Room *)room didDisconnectWithError:(LiveKitError *)error {
    [self.roomDidDisconnectExp fulfill];
}

- (void)room:(Room *)room participantDidConnect:(RemoteParticipant *)participant {
    self.connectedParticipant = participant;
    [self.participantDidConnectExp fulfill];
}

- (void)room:(Room *)room participantDidDisconnect:(RemoteParticipant *)participant {
    self.disconnectedParticipant = participant;
    [self.participantDidDisconnectExp fulfill];
}

// MARK: - Tests

- (void)testRoomDelegateCallbacks {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;
    NSString *token = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                         identity:@"delegate-test"
                                                       canPublish:NO
                                                   canPublishData:NO
                                                     canSubscribe:NO
                                                            error:&error];
    XCTAssertNil(error);

    Room *room = [[Room alloc] initWithDelegate:self connectOptions:nil roomOptions:nil];

    // Verify roomDidConnect fires
    self.roomDidConnectExp = [self expectationWithDescription:@"roomDidConnect"];
    XCTestExpectation *connectExp = [self expectationWithDescription:@"connectCompletion"];
    [room connectWithUrl:url token:token connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connectExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    // Verify room:didDisconnectWithError: fires
    self.roomDidDisconnectExp = [self expectationWithDescription:@"roomDidDisconnect"];
    XCTestExpectation *disconnectExp = [self expectationWithDescription:@"disconnectCompletion"];
    [room disconnectWithCompletionHandler:^{
        [disconnectExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

- (void)testParticipantDidConnect {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;

    NSString *token1 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"delegate-p1"
                                                        canPublish:NO
                                                    canPublishData:NO
                                                      canSubscribe:NO
                                                             error:&error];
    XCTAssertNil(error);

    NSString *token2 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"delegate-p2"
                                                        canPublish:NO
                                                    canPublishData:NO
                                                      canSubscribe:NO
                                                             error:&error];
    XCTAssertNil(error);

    // Connect room1 with self as delegate
    Room *room1 = [[Room alloc] initWithDelegate:self connectOptions:nil roomOptions:nil];

    XCTestExpectation *connect1 = [self expectationWithDescription:@"connect1"];
    [room1 connectWithUrl:url token:token1 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect1 fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    // Set up expectation for participant connect
    self.participantDidConnectExp = [self expectationWithDescription:@"participantDidConnect"];

    // Connect room2
    Room *room2 = [[Room alloc] initWithDelegate:nil connectOptions:nil roomOptions:nil];

    XCTestExpectation *connect2 = [self expectationWithDescription:@"connect2"];
    [room2 connectWithUrl:url token:token2 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect2 fulfill];
    }];
    [self waitForExpectations:@[connect2, self.participantDidConnectExp] timeout:30];

    XCTAssertNotNil(self.connectedParticipant);
    XCTAssertNotNil(self.connectedParticipant.identity);
    XCTAssertEqualObjects(self.connectedParticipant.identity.stringValue, @"delegate-p2");

    // Disconnect
    XCTestExpectation *disconnect1 = [self expectationWithDescription:@"disconnect1"];
    XCTestExpectation *disconnect2 = [self expectationWithDescription:@"disconnect2"];
    [room1 disconnectWithCompletionHandler:^{ [disconnect1 fulfill]; }];
    [room2 disconnectWithCompletionHandler:^{ [disconnect2 fulfill]; }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

- (void)testParticipantDidDisconnect {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;

    NSString *token1 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"disc-p1"
                                                        canPublish:NO
                                                    canPublishData:NO
                                                      canSubscribe:NO
                                                             error:&error];
    XCTAssertNil(error);

    NSString *token2 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"disc-p2"
                                                        canPublish:NO
                                                    canPublishData:NO
                                                      canSubscribe:NO
                                                             error:&error];
    XCTAssertNil(error);

    // Connect room1 with delegate
    Room *room1 = [[Room alloc] initWithDelegate:self connectOptions:nil roomOptions:nil];

    XCTestExpectation *connect1 = [self expectationWithDescription:@"connect1"];
    [room1 connectWithUrl:url token:token1 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect1 fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    // Set up participant join expectation
    self.participantDidConnectExp = [self expectationWithDescription:@"participantDidConnect"];

    // Connect room2
    Room *room2 = [[Room alloc] initWithDelegate:nil connectOptions:nil roomOptions:nil];

    XCTestExpectation *connect2 = [self expectationWithDescription:@"connect2"];
    [room2 connectWithUrl:url token:token2 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect2 fulfill];
    }];
    [self waitForExpectations:@[connect2, self.participantDidConnectExp] timeout:30];

    // Now set up disconnect expectation
    self.participantDidDisconnectExp = [self expectationWithDescription:@"participantDidDisconnect"];

    // Disconnect room2
    XCTestExpectation *disconnect2 = [self expectationWithDescription:@"disconnect2"];
    [room2 disconnectWithCompletionHandler:^{
        [disconnect2 fulfill];
    }];
    [self waitForExpectations:@[disconnect2, self.participantDidDisconnectExp] timeout:30];

    XCTAssertNotNil(self.disconnectedParticipant);

    // Disconnect room1
    XCTestExpectation *disconnect1 = [self expectationWithDescription:@"disconnect1"];
    [room1 disconnectWithCompletionHandler:^{ [disconnect1 fulfill]; }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

@end
