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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

// Physical iOS hardware only. In the Simulator, Metal textures live in the host GPU's memory and
// are not charged to the simulated process, so `phys_footprint` cannot see the drawable pool at
// all — the numbers below would all read zero and mean nothing. Run via the LKTestHost scheme.
//
// Mac Catalyst has to be excluded explicitly: it is `os(iOS)` and not a simulator, so it would
// otherwise compile and run here, on a Mac GPU with a Mac window server and none of the
// assumptions below holding.
#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
import MetalKit
import UIKit

/// On-device A/B of the drawable-size clamp: memory, draw cost, and image difference, measured on
/// real hardware where IOSurface allocations are charged to the app.
///
/// Both arms run in the same process so the comparison is not across builds. The "before" arm
/// reproduces the pre-fix allocation by assigning `drawableSize = videoSize * screenScale`
/// directly on the `MTKView` — which is all the old code path amounted to — and then drawing
/// without an intervening layout pass, since `-layoutSubviews` would recompute it.
@Suite(.tags(.media), .serialized)
@MainActor
struct VideoViewDeviceBenchmarkTests {
    // Four, not nine: the "before" arm allocates 213.6 MB of drawables per tile, so nine would ask
    // for ~1.9 GB and be jetsammed before it could be measured. Four lands near 850 MB, which an
    // iPhone survives — and the per-view figures scale linearly anyway.
    static let tiles = 4
    static let drawsPerArm = 30
    nonisolated static let video = RendererProbe.Resolution(width: 1920, height: 1080)
    nonisolated static let tileFrame = CGRect(x: 0, y: 0, width: 120, height: 68)

    struct Arm {
        let name: String
        let drawableSize: CGSize
        let footprintDelta: Int64
        let poolBytes: Int64
        let millisecondsPerDraw: Double
    }

    @Test
    func clampedVersusUnclampedOnDevice() async throws {
        let scale = UIScreen.main.scale
        let videoPixels = CGSize(width: CGFloat(Self.video.width), height: CGFloat(Self.video.height))
        let unclamped = CGSize(width: videoPixels.width * scale, height: videoPixels.height * scale)

        print("")
        print("=== on-device drawable benchmark ===")
        print("device=\(UIDevice.current.model) iOS=\(UIDevice.current.systemVersion) screenScale=\(scale)")
        print("tiles=\(Self.tiles) video=\(Self.video.label) " +
            "tile=\(Int(Self.tileFrame.width))x\(Int(Self.tileFrame.height))pt")
        print("`.auto` resolves to \(VideoView.shouldAvoidMetalRenderer ? ".sampleBuffer" : ".metal")")
        print("")

        // Absorb the one-time Metal costs (device, per-renderer shader library, command queue)
        // before either arm is measured, or the first one measured carries all of them.
        let warmUp = try await RendererProbe.Harness(renderMode: .metal,
                                                     resolution: Self.video,
                                                     frame: Self.tileFrame)
        warmUp.tearDown()
        try await RendererProbe.quiesce()

        let before = try await Self.measureArm(name: "before (video x scale)", forcedDrawableSize: unclamped)
        let after = try await Self.measureArm(name: "after (clamped)", forcedDrawableSize: nil)

        Self.report([before, after])

        #expect(after.poolBytes < before.poolBytes)
        // The headline claim: on real hardware the footprint must actually fall, not just the
        // arithmetic. Allow slack for allocator noise around a difference this large.
        #expect(after.footprintDelta < before.footprintDelta,
                "clamped arm did not reduce measured footprint")
    }

    private static func measureArm(name: String, forcedDrawableSize: CGSize?) async throws -> Arm {
        // The previous arm can have released close to a gigabyte, and the footprint ledger lags
        // that by a noticeable margin. Taking the baseline too early makes the next arm's delta
        // absorb the tail of that reclaim — which showed up as a negative figure.
        try await RendererProbe.quiesce()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        try await RendererProbe.quiesce()
        let baseline = RendererProbe.physFootprint()

        var harnesses: [RendererProbe.Harness] = []
        var metalViews: [MTKView] = []
        for _ in 0 ..< tiles {
            let harness = try await RendererProbe.Harness(renderMode: .metal,
                                                          resolution: video,
                                                          frame: tileFrame)
            harnesses.append(harness)
            if let metalView = RendererProbe.metalView(in: harness.view) {
                if let forcedDrawableSize { metalView.drawableSize = forcedDrawableSize }
                metalViews.append(metalView)
            }
        }

        // Each pass captures a fresh frame per tile so `drawInMTKView:` cannot skip it as a
        // duplicate, and lays nothing out so a forced `drawableSize` survives the loop.
        let drawnViews = metalViews.count
        var elapsed: TimeInterval = 0
        for _ in 0 ..< drawsPerArm {
            for harness in harnesses {
                elapsed += try await harness.captureAndDrawWithoutLayout()
            }
        }

        // Let presentation settle so every drawable in each pool has actually been realised.
        try await Task.sleep(nanoseconds: 400_000_000)

        let peak = RendererProbe.physFootprint()
        let drawableSize = metalViews.first?.drawableSize ?? .zero
        let maximumDrawableCount = (metalViews.first?.layer as? CAMetalLayer)?.maximumDrawableCount ?? 3
        let poolBytes = Int64(drawableSize.width * drawableSize.height) * 4 * Int64(maximumDrawableCount)

        for harness in harnesses {
            harness.tearDown()
        }
        harnesses.removeAll()
        metalViews.removeAll()
        try await RendererProbe.quiesce()

        let totalDraws = Double(drawsPerArm * max(drawnViews, 1))
        return Arm(name: name,
                   drawableSize: drawableSize,
                   footprintDelta: (peak - baseline) / Int64(tiles),
                   poolBytes: poolBytes,
                   millisecondsPerDraw: elapsed * 1000 / totalDraws)
    }

    private static func report(_ arms: [Arm]) {
        func pad(_ value: String, _ width: Int) -> String {
            value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
        }
        func padLeft(_ value: String, _ width: Int) -> String {
            value.count >= width ? value : String(repeating: " ", count: width - value.count) + value
        }

        let header = pad("arm", 26) + pad("drawableSize", 14) + padLeft("pool MB/view", 14) +
            padLeft("footprint MB/view", 19) + padLeft("ms/draw", 10)
        print(header)
        print(String(repeating: "-", count: header.count))
        for arm in arms {
            print(pad(arm.name, 26) +
                pad("\(Int(arm.drawableSize.width))x\(Int(arm.drawableSize.height))", 14) +
                padLeft(RendererProbe.mb(arm.poolBytes), 14) +
                padLeft(RendererProbe.mb(arm.footprintDelta), 19) +
                padLeft(String(format: "%.2f", arm.millisecondsPerDraw), 10))
        }
        print("")
        if let before = arms.first, let after = arms.last, after.poolBytes > 0 {
            let totalBefore = before.poolBytes * Int64(tiles)
            let totalAfter = after.poolBytes * Int64(tiles)
            print("across \(tiles) tiles: pool \(RendererProbe.mb(totalBefore)) MB -> " +
                "\(RendererProbe.mb(totalAfter)) MB " +
                "(\(String(format: "%.1f", Double(before.poolBytes) / Double(after.poolBytes)))x smaller)")
        }
        print("")
    }

    /// Captures each arm and reports how much the displayed image actually differs.
    ///
    /// `drawHierarchy(in:afterScreenUpdates:)` composites Metal content on device, unlike
    /// `CALayer.render(in:)`. Both arms show the same source frame, so a correct clamp leaves only
    /// resampling noise; a geometry or cropping regression would show up as a large difference.
    @Test(arguments: [RendererProbe.Pattern.gradient, .checkerboard])
    func clampDoesNotChangeTheDisplayedImage(_ pattern: RendererProbe.Pattern) async throws {
        let scale = UIScreen.main.scale
        let unclamped = CGSize(width: CGFloat(Self.video.width) * scale, height: CGFloat(Self.video.height) * scale)
        // Large enough that differences are visible rather than lost in a thumbnail.
        let frame = CGRect(x: 0, y: 0, width: 360, height: 203)

        let harness = try await RendererProbe.Harness(renderMode: .metal, resolution: Self.video,
                                                      frame: frame, pattern: pattern)
        defer { harness.tearDown() }
        let metalView = try #require(RendererProbe.metalView(in: harness.view))

        // A `CAMetalLayer` outside a window never presents, and `drawHierarchy` then keeps
        // returning the same stale capture — which makes every comparison read zero. Hosting the
        // view in the app's real window is what makes the snapshots reflect each render.
        // A sleeping or locked display stops compositing, so nothing presents and every snapshot
        // comes back stale — which reads as a difference of zero everywhere, control included.
        UIApplication.shared.isIdleTimerDisabled = true
        let window = try #require(Self.keyWindow(), "no key window; run under the LKTestHost app")
        window.makeKeyAndVisible()
        window.addSubview(harness.view)
        defer { harness.view.removeFromSuperview() }
        harness.layOut()
        try await Task.sleep(nanoseconds: 300_000_000)

        let clampedShot = try #require(Self.snapshot(harness.view))

        // Force the pre-fix size and render into it for real. A fresh capture per pass is what
        // stops `drawInMTKView:` skipping the frame as a duplicate; without it the layer would
        // keep showing the previous contents and the two snapshots would match trivially.
        metalView.drawableSize = unclamped
        for _ in 0 ..< 8 {
            try await harness.captureAndDrawWithoutLayout()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        try #require(metalView.drawableSize == unclamped, "forced drawable size did not survive")
        let unclampedShot = try #require(Self.snapshot(harness.view))

        // A snapshot that failed to composite the Metal layer would be flat, and two flat images
        // match perfectly — which would make the comparison below pass without testing anything.
        let variation = try #require(Self.standardDeviation(clampedShot))
        print("[image] pattern=\(pattern) clamped snapshot stddev=\(String(format: "%.2f", variation)) " +
            "(0 would mean a blank capture)")
        try #require(variation > 2.0, "snapshot is flat; drawHierarchy did not capture Metal content")

        let difference = try #require(Self.meanAbsoluteDifference(clampedShot, unclampedShot))
        print("[image] pattern=\(pattern) clamped vs unclamped mean abs difference: " +
            "\(String(format: "%.3f", difference)) / 255 over \(Int(frame.width))x\(Int(frame.height))pt")

        // Negative control. Without it a difference of 0 is ambiguous: it could mean the images
        // match, or that the comparison cannot see a difference at all. Render deliberately far
        // below the displayed size — that must register, or the measurement above means nothing.
        metalView.drawableSize = CGSize(width: 48, height: 27)
        for _ in 0 ..< 8 {
            try await harness.captureAndDrawWithoutLayout()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let degradedShot = try #require(Self.snapshot(harness.view))
        let degradedDifference = try #require(Self.meanAbsoluteDifference(clampedShot, degradedShot))
        print("[image] pattern=\(pattern) negative control (48x27 drawable) difference: " +
            "\(String(format: "%.3f", degradedDifference)) / 255")
        // Only a relative check: a smooth gradient survives even a 48x27 render almost intact,
        // so an absolute floor here would encode the pattern rather than the property.
        #expect(degradedDifference > difference,
                "comparison cannot tell a known-bad render from the clamp, so the figure above is not meaningful")

        Self.writePNG(clampedShot, named: "clamped-\(pattern).png")
        Self.writePNG(unclampedShot, named: "unclamped-\(pattern).png")
        Self.writePNG(degradedShot, named: "degraded-control-\(pattern).png")

        // Judged against the control rather than an absolute number: what matters is that the
        // clamp sits far closer to the reference than a knowingly degraded render does. An
        // absolute threshold would just encode whatever this particular pattern happens to score.
        #expect(difference < degradedDifference / 2,
                "clamp differs \(difference)/255 vs \(degradedDifference)/255 for a broken render")
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.flatMap(\.windows).first
    }

    private static func snapshot(_ view: UIView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        return renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    /// Luma standard deviation, used only to prove a snapshot actually contains an image.
    private static func standardDeviation(_ image: UIImage) -> Double? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sum = 0.0, sumOfSquares = 0.0
        let count = width * height
        for index in stride(from: 0, to: buffer.count, by: 4) {
            let luma = 0.299 * Double(buffer[index]) + 0.587 * Double(buffer[index + 1])
                + 0.114 * Double(buffer[index + 2])
            sum += luma
            sumOfSquares += luma * luma
        }
        let mean = sum / Double(count)
        return (sumOfSquares / Double(count) - mean * mean).squareRoot()
    }

    private static func meanAbsoluteDifference(_ lhs: UIImage, _ rhs: UIImage) -> Double? {
        guard let a = lhs.cgImage, let b = rhs.cgImage,
              a.width == b.width, a.height == b.height else { return nil }
        let width = a.width, height = a.height
        let bytesPerRow = width * 4
        var bufferA = [UInt8](repeating: 0, count: bytesPerRow * height)
        var bufferB = [UInt8](repeating: 0, count: bytesPerRow * height)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let contextA = CGContext(data: &bufferA, width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: bytesPerRow, space: space, bitmapInfo: info),
            let contextB = CGContext(data: &bufferB, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: bytesPerRow, space: space, bitmapInfo: info)
        else { return nil }
        contextA.draw(a, in: CGRect(x: 0, y: 0, width: width, height: height))
        contextB.draw(b, in: CGRect(x: 0, y: 0, width: width, height: height))

        var total = 0.0
        for index in stride(from: 0, to: bufferA.count, by: 4) {
            total += Double(abs(Int(bufferA[index]) - Int(bufferB[index])))
            total += Double(abs(Int(bufferA[index + 1]) - Int(bufferB[index + 1])))
            total += Double(abs(Int(bufferA[index + 2]) - Int(bufferB[index + 2])))
        }
        return total / Double(width * height * 3)
    }

    private static func writePNG(_ image: UIImage, named name: String) {
        guard let data = image.pngData() else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        try? data.write(to: url)
        print("[image] wrote \(url.path)")
    }
}
#endif
