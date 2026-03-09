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

// Cross-ref: Tests/LiveKitCoreTests/RpcTests.swift

@import XCTest;
@import LiveKit;
@import LiveKitTestSupport;

@interface RpcObjCTests : XCTestCase <RoomDelegate>
@property (nonatomic, strong) XCTestExpectation *participantJoinedExp;
@end

@implementation RpcObjCTests

- (void)room:(Room *)room participantDidConnect:(RemoteParticipant *)participant {
    [self.participantJoinedExp fulfill];
}

#pragma mark - Tests

- (void)testRegisterAndCallRpc {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;

    NSString *token0 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"rpc-responder"
                                                        canPublish:NO
                                                    canPublishData:YES
                                                      canSubscribe:YES
                                                             error:&error];
    XCTAssertNil(error);

    NSString *token1 = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                          identity:@"rpc-caller"
                                                        canPublish:NO
                                                    canPublishData:YES
                                                      canSubscribe:YES
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

    self.participantJoinedExp = [self expectationWithDescription:@"participantJoined"];

    // Connect room1
    XCTestExpectation *connect1 = [self expectationWithDescription:@"connect1"];
    [room1 connectWithUrl:url token:token1 connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connect1 fulfill];
    }];
    [self waitForExpectations:@[connect1, self.participantJoinedExp] timeout:30];

    // Register RPC method on room0
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [room0 registerRpcMethod:@"greet" handler:^NSString *(ParticipantIdentity *callerIdentity, NSString *payload) {
        return [NSString stringWithFormat:@"Hello, %@!", payload];
    } onError:nil];
#pragma clang diagnostic pop

    // Brief pause for registration to complete
    [NSThread sleepForTimeInterval:1.0];

    // Call RPC from room1
    ParticipantIdentity *responderIdentity = [[ParticipantIdentity alloc] initFrom:@"rpc-responder"];
    XCTestExpectation *rpcExp = [self expectationWithDescription:@"rpcResponse"];
    __block NSString *rpcResponse = nil;

    [room1.localParticipant performRpcWithDestinationIdentity:responderIdentity
                                                       method:@"greet"
                                                      payload:@"World"
                                              responseTimeout:15.0
                                            completionHandler:^(NSString *response, NSError *err) {
        XCTAssertNil(err);
        rpcResponse = response;
        [rpcExp fulfill];
    }];

    [self waitForExpectationsWithTimeout:30 handler:nil];

    XCTAssertEqualObjects(rpcResponse, @"Hello, World!");

    // Disconnect
    XCTestExpectation *disconnect0 = [self expectationWithDescription:@"disconnect0"];
    XCTestExpectation *disconnect1 = [self expectationWithDescription:@"disconnect1"];
    [room0 disconnectWithCompletionHandler:^{ [disconnect0 fulfill]; }];
    [room1 disconnectWithCompletionHandler:^{ [disconnect1 fulfill]; }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

- (void)testUnregisterRpc {
    NSString *roomName = [[NSUUID UUID] UUIDString];
    NSString *url = [LKObjCRoomHelper serverURL];
    NSError *error = nil;

    NSString *token = [LKObjCRoomHelper generateTokenWithRoomName:roomName
                                                         identity:@"rpc-unreg"
                                                       canPublish:NO
                                                   canPublishData:YES
                                                     canSubscribe:YES
                                                            error:&error];
    XCTAssertNil(error);

    Room *room = [[Room alloc] initWithDelegate:nil connectOptions:nil roomOptions:nil];

    XCTestExpectation *connectExp = [self expectationWithDescription:@"connect"];
    [room connectWithUrl:url token:token connectOptions:nil roomOptions:nil completionHandler:^(NSError *err) {
        XCTAssertNil(err);
        [connectExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:30 handler:nil];

    // Register RPC method
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [room registerRpcMethod:@"test-method" handler:^NSString *(ParticipantIdentity *callerIdentity, NSString *payload) {
        return @"response";
    } onError:nil];
#pragma clang diagnostic pop

    [NSThread sleepForTimeInterval:1.0];

    // Verify it's registered (auto-generated completionHandler variant)
    XCTestExpectation *isRegisteredExp = [self expectationWithDescription:@"isRegistered"];
    [room isRpcMethodRegistered:@"test-method" completionHandler:^(BOOL result) {
        XCTAssertTrue(result);
        [isRegisteredExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];

    // Unregister (auto-generated completionHandler variant)
    XCTestExpectation *unregisterExp = [self expectationWithDescription:@"unregistered"];
    [room unregisterRpcMethod:@"test-method" completionHandler:^{
        [unregisterExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];

    // Verify it's no longer registered
    XCTestExpectation *notRegisteredExp = [self expectationWithDescription:@"notRegistered"];
    [room isRpcMethodRegistered:@"test-method" completionHandler:^(BOOL result) {
        XCTAssertFalse(result);
        [notRegisteredExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];

    // Disconnect
    XCTestExpectation *disconnectExp = [self expectationWithDescription:@"disconnect"];
    [room disconnectWithCompletionHandler:^{ [disconnectExp fulfill]; }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

@end
