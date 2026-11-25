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

import CoreVideo
import Foundation
@testable import LiveKit
import Testing

#if os(iOS) || os(macOS)
import MetalKit

extension RendererProbe {
    /// Records which renderer `.auto` actually picks here, so a run on a host that diverges from a
    /// real device cannot be mistaken for one that does not.
    @MainActor
    static func reportEnvironment() {
        let resolved = VideoView.shouldAvoidMetalRenderer ? ".sampleBuffer" : ".metal"
        print("")
        print("[env] isMetalAvailable=\(VideoView.isMetalAvailable()) " +
            "shouldAvoidMetalRenderer=\(VideoView.shouldAvoidMetalRenderer) -> .auto resolves to \(resolved)")
        #if targetEnvironment(simulator)
        print("[env] SIMULATOR: GPU is the host's; `.auto` diverges from a real A14+ iPhone, " +
            "so the rows below force `.metal` explicitly.")
        #endif
    }

    static func report(_ rows: [Row]) {
        func pad(_ value: String, _ width: Int) -> String {
            value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
        }
        func padLeft(_ value: String, _ width: Int) -> String {
            value.count >= width ? value : String(repeating: " ", count: width - value.count) + value
        }

        print("")
        print("=== VideoView renderer footprint (decoder excluded, \(viewsPerSample) views per sample) ===")
        print("view frame: \(Int(viewFrame.width))x\(Int(viewFrame.height)) for every row")
        print("")
        let header = pad("mode", 15) + pad("video", 12) + pad("drawableSize", 14) + padLeft("maxDraw", 8) +
            padLeft("drawables MB", 14) + padLeft("footprint MB", 14) + padLeft("reclaimed MB", 14)
        print(header)
        print(String(repeating: "-", count: header.count))
        for row in rows {
            let mode = row.renderMode == .metal ? ".metal" : ".sampleBuffer"
            let drawable = row.drawableSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "n/a"
            let maxDrawable = row.maximumDrawableCount.map(String.init) ?? "n/a"
            var drawablesMB = "n/a"
            if let size = row.drawableSize, let count = row.maximumDrawableCount {
                drawablesMB = mb(Int64(size.width * size.height) * 4 * Int64(count))
            }
            print(pad(mode, 15) + pad(row.resolution.label, 12) + pad(drawable, 14) +
                padLeft(maxDrawable, 8) + padLeft(drawablesMB, 14) +
                padLeft(mb(row.perViewBytes), 14) + padLeft(mb(row.reclaimedBytes), 14))
        }
        print("")
        print("drawables MB = drawableSize.w * drawableSize.h * 4 (BGRA8) * maximumDrawableCount")
        print("             = what CAMetalLayer must allocate, by construction")
        print("footprint MB = measured phys_footprint delta per view")
        print("NV12 frame at 1920x1080 = \(mb(reported.nv12Bytes)) MB (what was measured as '<4 MB')")
        print("")
    }
}
#endif
