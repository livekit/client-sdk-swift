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

// Cross-ref: Tests/LiveKitCoreTests/DataStream/StreamOptionsTests.swift
//
// Guards that DataStreamOptions stays usable from Objective-C (it's a class, not a struct, so it
// bridges) and that adding it to RoomOptions did not drop RoomOptions's Objective-C initializer.

@import XCTest;
@import LiveKit;

@interface DataStreamOptionsObjCTests : XCTestCase
@end

@implementation DataStreamOptionsObjCTests

- (void)testDataStreamOptionsConstructibleFromObjC {
    DataStreamOptions *defaults = [[DataStreamOptions alloc] init];
    XCTAssertNil(defaults.maxPayloadSizeNumber);

    DataStreamOptions *capped = [[DataStreamOptions alloc] initWithMaxPayloadSizeNumber:@1024];
    XCTAssertEqualObjects(capped.maxPayloadSizeNumber, @1024);

    XCTAssertEqualObjects(capped, [[DataStreamOptions alloc] initWithMaxPayloadSizeNumber:@1024]);
    XCTAssertNotEqualObjects(capped, defaults);
}

- (void)testRoomOptionsRetainsObjCInitializerWithDataStreamOptions {
    // Adding a value type here would have dropped RoomOptions's Objective-C initializer entirely
    // (Swift won't export an init that takes an ObjC-unrepresentable parameter). Because
    // DataStreamOptions is a class, the designated initializer — which takes `dataStreamOptions:` —
    // must remain callable from Objective-C. The sub-option parameters have their own
    // ObjC-unavailable initializers (pre-existing), so we assert the selector exists rather than
    // invoking it.
    SEL initializer = @selector(initWithDefaultCameraCaptureOptions:
                                defaultScreenShareCaptureOptions:
                                defaultAudioCaptureOptions:
                                defaultVideoPublishOptions:
                                defaultAudioPublishOptions:
                                defaultDataPublishOptions:
                                dataStreamOptions:
                                adaptiveStream:
                                dynacast:
                                stopLocalTrackOnUnpublish:
                                suspendLocalVideoTracksInBackground:
                                e2eeOptions:
                                encryptionOptions:
                                reportRemoteTrackStatistics:
                                singlePeerConnection:);
    XCTAssertTrue([RoomOptions instancesRespondToSelector:initializer],
                  @"RoomOptions must keep its Objective-C initializer accepting dataStreamOptions:");
}

@end
