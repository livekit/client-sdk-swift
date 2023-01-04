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

import Foundation
import WebRTC

@available(*, deprecated)
public extension VideoParameters {

    // 4:3 aspect ratio
    static let presetQVGA43 = VideoParameters(
        dimensions: .qvga43,
        encoding: VideoEncoding(maxBitrate: 90_000, maxFps: 10)
    )

    static let presetVGA43 = VideoParameters(
        dimensions: .vga43,
        encoding: VideoEncoding(maxBitrate: 225_000, maxFps: 20)
    )

    static let presetQHD43 = VideoParameters(
        dimensions: .qhd43,
        encoding: VideoEncoding(maxBitrate: 450_000, maxFps: 25)
    )

    static let presetHD43 = VideoParameters(
        dimensions: .hd43,
        encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 30)
    )

    static let presetFHD43 = VideoParameters(
        dimensions: .fhd43,
        encoding: VideoEncoding(maxBitrate: 2_800_000, maxFps: 30)
    )

    // 16:9 aspect ratio
    static let presetQVGA169 = VideoParameters(
        dimensions: .qvga169,
        encoding: VideoEncoding(maxBitrate: 120_000, maxFps: 10)
    )

    static let presetVGA169 = VideoParameters(
        dimensions: .vga169,
        encoding: VideoEncoding(maxBitrate: 300_000, maxFps: 20)
    )

    static let presetQHD169 = VideoParameters(
        dimensions: .qhd169,
        encoding: VideoEncoding(maxBitrate: 600_000, maxFps: 25)
    )

    static let presetHD169 = VideoParameters(
        dimensions: .hd169,
        encoding: VideoEncoding(maxBitrate: 2_000_000, maxFps: 30)
    )

    static let presetFHD169 = VideoParameters(
        dimensions: .fhd169,
        encoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 30)
    )

    // Screen share
    static let presetScreenShareVGA = VideoParameters(
        dimensions: .vga169,
        encoding: VideoEncoding(maxBitrate: 200_000, maxFps: 3)
    )

    static let presetScreenShareHD5 = VideoParameters(
        dimensions: .hd169,
        encoding: VideoEncoding(maxBitrate: 400_000, maxFps: 5)
    )

    static let presetScreenShareHD15 = VideoParameters(
        dimensions: .hd169,
        encoding: VideoEncoding(maxBitrate: 1_000_000, maxFps: 15)
    )

    static let presetScreenShareFHD15 = VideoParameters(
        dimensions: .fhd169,
        encoding: VideoEncoding(maxBitrate: 1_500_000, maxFps: 15)
    )

    static let presetScreenShareFHD30 = VideoParameters(
        dimensions: .fhd169,
        encoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 30)
    )
}
