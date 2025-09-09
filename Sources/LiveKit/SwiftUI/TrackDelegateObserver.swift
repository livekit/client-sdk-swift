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

import Foundation

/// Helper class to observer ``TrackDelegate`` from Swift UI.
public class TrackDelegateObserver: ObservableObject, TrackDelegate, @unchecked Sendable {
    private let track: Track

    @Published public var dimensions: Dimensions?
    @Published public var statistics: TrackStatistics?
    @Published public var simulcastStatistics: [VideoCodec: TrackStatistics]

    public var allStatisticts: [TrackStatistics] {
        var result: [TrackStatistics] = []
        if let statistics {
            result.append(statistics)
        }
        result.append(contentsOf: simulcastStatistics.values)
        return result
    }

    public init(track: Track) {
        self.track = track

        dimensions = track.dimensions
        statistics = track.statistics
        simulcastStatistics = track.simulcastStatistics

        track.add(delegate: self)
    }

    // MARK: - TrackDelegate

    public func track(_: VideoTrack, didUpdateDimensions dimensions: Dimensions?) {
        Task { @MainActor in
            self.dimensions = dimensions
        }
    }

    public func track(_: Track, didUpdateStatistics statistics: TrackStatistics, simulcastStatistics: [VideoCodec: TrackStatistics]) {
        Task { @MainActor in
            self.statistics = statistics
            self.simulcastStatistics = simulcastStatistics
        }
    }
}
