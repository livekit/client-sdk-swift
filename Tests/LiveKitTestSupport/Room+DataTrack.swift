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

import Foundation
@testable import LiveKit
import LiveKitUniFFI

/// Waits for a remote data track to be published by observing data track delegate events.
public extension Room {
    func waitForDataTrack(name: String, timeout: TimeInterval = 10) async throws -> RemoteDataTrack {
        let watcher = DataTrackWatcher(expectedName: name)
        dataTrackDelegates.add(delegate: watcher)
        defer { dataTrackDelegates.remove(delegate: watcher) }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let track = watcher.publishedTrack {
                return track
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms poll
        }

        throw LiveKitError(.timedOut, message: "Timed out waiting for data track '\(name)'")
    }
}

final class DataTrackWatcher: DataTrackDelegate, @unchecked Sendable {
    let expectedName: String
    private let lock = NSLock()
    private var _publishedTrack: RemoteDataTrack?

    var publishedTrack: RemoteDataTrack? {
        lock.withLock { _publishedTrack }
    }

    init(expectedName: String) {
        self.expectedName = expectedName
    }

    func room(_: Room, didPublishDataTrack track: RemoteDataTrack) {
        if track.info().name == expectedName {
            lock.withLock { _publishedTrack = track }
        }
    }
}
