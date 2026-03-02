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

// Cross-ref: Tests/LiveKitCoreTests/Room/RoomTests.swift

@import XCTest;
@import LiveKit;
@import LiveKitTestSupport;

@interface RoomObjCTests : XCTestCase
@end

@implementation RoomObjCTests

- (void)testRoomInitialization {
    Room *room = [[Room alloc] initWithDelegate:nil connectOptions:nil roomOptions:nil];
    XCTAssertNotNil(room);
    XCTAssertEqual(room.connectionState, ConnectionStateDisconnected);
    XCTAssertNil(room.sid);
    XCTAssertNil(room.name);
    XCTAssertNotNil(room.localParticipant);
}

- (void)testRoomConnectDisconnect {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;
    NSString *token = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                         identity:@"objc-connect-test"
                                                       canPublish:NO
                                                   canPublishData:NO
                                                     canSubscribe:NO
                                                            error:&error];
    XCTAssertNil(error);
    XCTAssertNotNil(token);

    Room *room = [[Room alloc] initWithDelegate:nil connectOptions:nil roomOptions:nil];

    // Connect
    XCTestExpectation *connectExp = [self expectationWithDescription:@"connect"];
    [room connectWithUrl:url token:token connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connectExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    XCTAssertEqual(room.connectionState, ConnectionStateConnected);

    // Disconnect
    XCTestExpectation *disconnectExp = [self expectationWithDescription:@"disconnect"];
    [room disconnectWithCompletionHandler:^{
        [disconnectExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];

    XCTAssertEqual(room.connectionState, ConnectionStateDisconnected);
}

- (void)testRoomProperties {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;
    NSString *token = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                         identity:@"objc-props-test"
                                                       canPublish:NO
                                                   canPublishData:NO
                                                     canSubscribe:NO
                                                            error:&error];
    XCTAssertNil(error);

    Room *room = [[Room alloc] initWithDelegate:nil connectOptions:nil roomOptions:nil];

    // Connect
    XCTestExpectation *connectExp = [self expectationWithDescription:@"connect"];
    [room connectWithUrl:url token:token connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connectExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    // Verify properties
    XCTAssertNotNil(room.sid);
    XCTAssertTrue([room.sid.stringValue hasPrefix:@"RM_"]);
    XCTAssertNotNil(room.name);
    XCTAssertTrue(room.name.length > 0);
    XCTAssertNotNil(room.creationTime);
    XCTAssertNotNil(room.localParticipant);
    XCTAssertEqual(room.connectionState, ConnectionStateConnected);
    XCTAssertNotNil(room.url);
    XCTAssertNotNil(room.token);

    // Disconnect
    XCTestExpectation *disconnectExp = [self expectationWithDescription:@"disconnect"];
    [room disconnectWithCompletionHandler:^{
        [disconnectExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

- (void)testLocalParticipantIdentity {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;
    NSString *token = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                         identity:@"objc-identity-test"
                                                       canPublish:NO
                                                   canPublishData:NO
                                                     canSubscribe:NO
                                                            error:&error];
    XCTAssertNil(error);

    Room *room = [[Room alloc] initWithDelegate:nil connectOptions:nil roomOptions:nil];

    // Connect
    XCTestExpectation *connectExp = [self expectationWithDescription:@"connect"];
    [room connectWithUrl:url token:token connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connectExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    XCTAssertNotNil(room.localParticipant.identity);
    XCTAssertTrue(room.localParticipant.identity.stringValue.length > 0);

    // Disconnect
    XCTestExpectation *disconnectExp = [self expectationWithDescription:@"disconnect"];
    [room disconnectWithCompletionHandler:^{
        [disconnectExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

@end
