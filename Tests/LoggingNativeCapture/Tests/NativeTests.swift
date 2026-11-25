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

import Compression
import Foundation
@testable import LiveKit
import LiveKitFFI
import Testing

// OTLP is protobuf binary; these fixture checks deliberately search its ASCII fields.
// swiftlint:disable optional_data_string_conversion
private final class MemoryTransport: TelemetryTransport, Sendable {
    let requests = StateSync<[ExportRequest]>([])
    func send(request: ExportRequest) async throws -> ExportResponse {
        requests.mutate { $0.append(request) }
        return ExportResponse(status: 200, headers: [:], body: Data())
    }

    func bodies() throws -> [String] {
        try requests.copy().map { request in
            if request.headers["Content-Encoding"] == nil, request.headers["content-encoding"] == nil {
                return String(decoding: request.body, as: UTF8.self)
            }
            let data = request.body
            try #require(data.count > 18 && Array(data.prefix(4)) == [31, 139, 8, 0])
            let payload = data.dropFirst(10).dropLast(8)
            var output = [UInt8](repeating: 0, count: 1_048_576)
            let size = payload.withUnsafeBytes { bytes in
                compression_decode_buffer(&output, output.count, bytes.bindMemory(to: UInt8.self).baseAddress!, payload.count, nil, COMPRESSION_ZLIB)
            }
            try #require(size > 0 && size < output.count)
            return String(decoding: output.prefix(size), as: UTF8.self)
        }
    }
}

private final class LocalDelegate: RemoteDataTrackManagerDelegate {
    func onSignalRequest(request _: Data) {}
    func onTrackPublished(track _: LiveKitFFI.RemoteDataTrack) {}
    func onTrackUnpublished(sid _: DataTrackSid) {}
}

// swiftlint:enable optional_data_string_conversion

private struct CustomConsole: Logger {
    // swiftlint:disable:next function_parameter_count
    func log(_: @autoclosure () -> CustomStringConvertible, _: LogLevel,
             source _: @autoclosure () -> String?, file _: StaticString, type _: Any.Type,
             function _: StaticString, line _: UInt, metaData _: ScopedMetadataContainer) {}
}

/// Each entry must run in a fresh test process: Rust logger and consent are process-wide.
struct NativeTests {
    @Test func noConsole() async throws { try await run("none") }
    @Test func customConsole() async throws { try await run("custom") }
    @Test func disabledConsole() async throws { try await run("off") }
    @Test func concurrentInitialization() async throws { try await run("concurrent") }
    @Test func ffiFalse() async throws { try await run("ffiFalse") }
    @Test func defaultConsole() async throws { try await run("default") }
    @Test func consoleBeforeTelemetry() async throws { try await run("before") }
    @Test func telemetryBeforeConsole() async throws { try await run("after") }
    @Test func optOutBeforeInstall() async throws { try await run("disabled") }

    // Keep the process-global consent and native owner lifetime in one fixture scope.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func run(_ mode: String) async throws {
        let transport = MemoryTransport()
        var console: OSLogger?
        if mode == "custom" { LiveKitSDK.setLogger(CustomConsole()); _ = sharedLogger }
        if mode == "off" { LiveKitSDK.disableLogging(); _ = sharedLogger }
        if mode == "ffiFalse" { console = OSLogger(ffi: false) }
        if mode == "default" { console = OSLogger() }
        if mode == "before" { NativeLogBootstrap.console(level: .error) }
        if mode == "disabled" { Telemetry.disable(); await Telemetry.cleanUpFinished() }
        let installed = StateSync(false)
        var installError: Error?
        Telemetry.configure {
            installed.mutate { $0 = true }
            do { try telemetryConfigure(config: TelemetryConfig(flushIntervalMs: 3_600_000), transport: transport, instruments: []) } catch { installError = error }
        }
        if let installError { throw installError }
        if mode == "after" { NativeLogBootstrap.console(level: .error); NativeLogBootstrap.telemetry() }
        if mode == "concurrent" {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 20 {
                    group.addTask { NativeLogBootstrap.console(level: .error) }
                    group.addTask { NativeLogBootstrap.telemetry() }
                }
            }
        }
        let claims = Data("{\"exp\":4102444800,\"observability\":{\"write\":true}}".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let scope = telemetryScope()
        scope?.setServer(url: "wss://logging-fixture.livekit.cloud", token: "e30.\(claims).synthetic")
        var delivery: LocalDelegate? = LocalDelegate()
        weak var weakDelivery = delivery
        var manager: LiveKitFFI.RemoteDataTrackManager? = LiveKitFFI.RemoteDataTrackManager(delegate: delivery!, decryptionProvider: nil)
        manager?.handlePacketReceived(packet: Data())
        var body = ""
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            await telemetryFlush()
            body = try transport.bodies().joined()
            if body.contains("Failed to deserialize packet") { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline && mode != "disabled"
        let count = body.components(separatedBy: "Failed to deserialize packet").count - 1
        #expect(installed.copy() == (mode != "disabled"))
        #expect(count == (mode == "disabled" ? 0 : 1))
        if mode != "disabled" {
            #expect(body.contains("livekit_datatrack::remote::manager"))
            #expect(body.contains("code.file.path"))
            #expect(body.contains("livekit-datatrack/src/remote/manager.rs"))
        }
        if ["before", "after", "concurrent"].contains(mode) {
            let entry = await logForwardReceive()
            #expect(entry?.message.contains("Failed to deserialize packet") == true)
        }
        print("NATIVE_PRODUCER mode=\(mode) records=\(count) native_file_metadata=\(body.contains("code.file.path"))")
        telemetryDisable()
        if mode == "none" {
            NativeLogBootstrap.console(level: .error)
            manager?.handlePacketReceived(packet: Data())
            let afterOptOut = await logForwardReceive()
            #expect(afterOptOut?.message.contains("Failed to deserialize packet") == true)
            let sends = transport.requests.copy().count
            await telemetryFlush()
            #expect(transport.requests.copy().count == sends)
            print("NATIVE_POST_OPTOUT produced=true exported=false")
        }
        manager = nil
        delivery = nil
        let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while weakDelivery != nil, ContinuousClock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(weakDelivery == nil)
        await telemetryShutdown()
        withExtendedLifetime((scope, console)) {}
    }
}
