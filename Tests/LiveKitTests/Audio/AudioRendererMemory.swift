/*
 * Copyright 2025 LiveKit
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

@preconcurrency import AVFoundation
@testable import LiveKit
import LiveKitWebRTC
import XCTest

final class TestAudioRenderer: AudioRenderer {
    let id: String
    let onDeinit: (@Sendable () -> Void)?

    init(id: String = UUID().uuidString, onDeinit: (@Sendable () -> Void)? = nil) {
        self.id = id
        self.onDeinit = onDeinit
        print("TestAudioRenderer[\(id)] init")
    }

    deinit {
        print("TestAudioRenderer[\(id)] deinit")
        onDeinit?()
    }

    func render(pcmBuffer _: AVAudioPCMBuffer) {}
}

class AudioRendererTests: LKTestCase {
    // Test local audio renderer deallocation after removal
    func testLocalAudioRendererDeallocation() async throws {
        let deinitExpectation = expectation(description: "Renderer should deinit")

        weak var weakRenderer: TestAudioRenderer?

        // Create scope to ensure renderer is released
        autoreleasepool {
            let renderer = TestAudioRenderer(id: "local", onDeinit: {
                deinitExpectation.fulfill()
            })
            weakRenderer = renderer

            // Add renderer
            AudioManager.shared.add(localAudioRenderer: renderer)

            // Verify it was added
            XCTAssertNotNil(weakRenderer, "Renderer should exist while in scope")

            // Remove renderer
            AudioManager.shared.remove(localAudioRenderer: renderer)
        }

        // Wait for deallocation
        await fulfillment(of: [deinitExpectation], timeout: 3.0)

        // Verify renderer was deallocated
        XCTAssertNil(weakRenderer, "Renderer should be deallocated after removal and scope exit")
    }

    // Test remote audio renderer deallocation after removal
    func testRemoteAudioRendererDeallocation() async throws {
        let deinitExpectation = expectation(description: "Renderer should deinit")

        weak var weakRenderer: TestAudioRenderer?

        // Create scope to ensure renderer is released
        autoreleasepool {
            let renderer = TestAudioRenderer(id: "remote", onDeinit: {
                deinitExpectation.fulfill()
            })
            weakRenderer = renderer

            // Add renderer
            AudioManager.shared.add(remoteAudioRenderer: renderer)

            // Verify it was added
            XCTAssertNotNil(weakRenderer, "Renderer should exist while in scope")

            // Remove renderer
            AudioManager.shared.remove(remoteAudioRenderer: renderer)
        }

        // Wait for deallocation
        await fulfillment(of: [deinitExpectation], timeout: 3.0)

        // Verify renderer was deallocated
        XCTAssertNil(weakRenderer, "Renderer should be deallocated after removal and scope exit")
    }

    // Test renderer deallocation without explicit removal (weak reference should allow it)
    func testLocalAudioRendererWeakReference() async throws {
        let deinitExpectation = expectation(description: "Renderer should deinit")

        weak var weakRenderer: TestAudioRenderer?

        // Create scope to ensure renderer is released
        autoreleasepool {
            let renderer = TestAudioRenderer(id: "weak-local", onDeinit: {
                deinitExpectation.fulfill()
            })
            weakRenderer = renderer

            // Add renderer but don't remove it
            AudioManager.shared.add(localAudioRenderer: renderer)

            // Verify it was added
            XCTAssertNotNil(weakRenderer, "Renderer should exist while in scope")
        }

        // Wait for deallocation - should happen even without explicit removal
        await fulfillment(of: [deinitExpectation], timeout: 3.0)

        // Verify renderer was deallocated
        XCTAssertNil(weakRenderer, "Renderer should be deallocated after scope exit (weak reference)")
    }

    // Test remote renderer deallocation without explicit removal (weak reference should allow it)
    func testRemoteAudioRendererWeakReference() async throws {
        let deinitExpectation = expectation(description: "Renderer should deinit")

        weak var weakRenderer: TestAudioRenderer?

        // Create scope to ensure renderer is released
        autoreleasepool {
            let renderer = TestAudioRenderer(id: "weak-remote", onDeinit: {
                deinitExpectation.fulfill()
            })
            weakRenderer = renderer

            // Add renderer but don't remove it
            AudioManager.shared.add(remoteAudioRenderer: renderer)

            // Verify it was added
            XCTAssertNotNil(weakRenderer, "Renderer should exist while in scope")
        }

        // Wait for deallocation - should happen even without explicit removal
        await fulfillment(of: [deinitExpectation], timeout: 3.0)

        // Verify renderer was deallocated
        XCTAssertNil(weakRenderer, "Renderer should be deallocated after scope exit (weak reference)")
    }

    // Test multiple renderers
    func testMultipleRenderersDeallocation() async throws {
        let deinit1 = expectation(description: "Renderer 1 should deinit")
        let deinit2 = expectation(description: "Renderer 2 should deinit")

        weak var weakRenderer1: TestAudioRenderer?
        weak var weakRenderer2: TestAudioRenderer?

        autoreleasepool {
            let renderer1 = TestAudioRenderer(id: "multi-1", onDeinit: { deinit1.fulfill() })
            let renderer2 = TestAudioRenderer(id: "multi-2", onDeinit: { deinit2.fulfill() })

            weakRenderer1 = renderer1
            weakRenderer2 = renderer2

            // Add both renderers
            AudioManager.shared.add(localAudioRenderer: renderer1)
            AudioManager.shared.add(localAudioRenderer: renderer2)

            // Remove both
            AudioManager.shared.remove(localAudioRenderer: renderer1)
            AudioManager.shared.remove(localAudioRenderer: renderer2)
        }

        // Wait for both to deallocate
        await fulfillment(of: [deinit1, deinit2], timeout: 3.0)

        XCTAssertNil(weakRenderer1, "Renderer 1 should be deallocated")
        XCTAssertNil(weakRenderer2, "Renderer 2 should be deallocated")
    }

    // Test RemoteAudioTrack.add(audioRenderer:) memory management
    func testRemoteAudioTrackRendererDeallocation() async throws {
        let deinitExpectation = expectation(description: "Renderer should deinit")

        weak var weakRenderer: TestAudioRenderer?
        weak var weakTrack: RemoteAudioTrack?

        autoreleasepool {
            // Create a mock remote audio track
            let audioSource = RTC.createAudioSource(nil)
            let rtcTrack = RTC.createAudioTrack(source: audioSource)
            let track = RemoteAudioTrack(name: "remote-test-track",
                                         source: .microphone,
                                         track: rtcTrack,
                                         reportStatistics: false)
            weakTrack = track

            let renderer = TestAudioRenderer(id: "remote-track", onDeinit: {
                deinitExpectation.fulfill()
            })
            weakRenderer = renderer

            // Add renderer via RemoteAudioTrack
            track.add(audioRenderer: renderer)

            // Verify both exist
            XCTAssertNotNil(weakRenderer, "Renderer should exist while in scope")
            XCTAssertNotNil(weakTrack, "Track should exist while in scope")

            // Remove renderer
            track.remove(audioRenderer: renderer)
        }

        // Wait for deallocation
        await fulfillment(of: [deinitExpectation], timeout: 3.0)

        // Verify renderer was deallocated
        XCTAssertNil(weakRenderer, "Renderer should be deallocated after removal and scope exit")
    }

    // Test RemoteAudioTrack renderer weak reference without explicit removal
    func testRemoteAudioTrackRendererWeakReference() async throws {
        let deinitExpectation = expectation(description: "Renderer should deinit")

        weak var weakRenderer: TestAudioRenderer?

        autoreleasepool {
            // Create a mock remote audio track
            let audioSource = RTC.createAudioSource(nil)
            let rtcTrack = RTC.createAudioTrack(source: audioSource)
            let track = RemoteAudioTrack(name: "remote-test-track-weak",
                                         source: .microphone,
                                         track: rtcTrack,
                                         reportStatistics: false)

            let renderer = TestAudioRenderer(id: "remote-track-weak", onDeinit: {
                deinitExpectation.fulfill()
            })
            weakRenderer = renderer

            // Add renderer but don't remove it
            track.add(audioRenderer: renderer)

            XCTAssertNotNil(weakRenderer, "Renderer should exist while in scope")
        }

        // Wait for deallocation - should happen even without explicit removal
        await fulfillment(of: [deinitExpectation], timeout: 3.0)

        // Verify renderer was deallocated
        XCTAssertNil(weakRenderer, "Renderer should be deallocated after scope exit (weak reference)")
    }
}
