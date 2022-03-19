/*
 * Copyright 2022 LiveKit
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

internal struct TrackSettings {

    let enabled: Bool
    let dimensions: Dimensions

    init(enabled: Bool = true,
         dimensions: Dimensions = .zero) {

        self.enabled = enabled
        self.dimensions = dimensions
    }

    func copyWith(enabled: Bool? = nil, dimensions: Dimensions? = nil) -> TrackSettings {
        TrackSettings(enabled: enabled ?? self.enabled,
                      dimensions: dimensions ?? self.dimensions)
    }
}

extension TrackSettings: Equatable {

    static func == (lhs: TrackSettings, rhs: TrackSettings) -> Bool {
        lhs.enabled == rhs.enabled && lhs.dimensions == rhs.dimensions
    }
}

extension TrackSettings: CustomStringConvertible {

    var description: String {
        "TrackSettings(enabled: \(enabled), dimensions: \(dimensions))"
    }
}
