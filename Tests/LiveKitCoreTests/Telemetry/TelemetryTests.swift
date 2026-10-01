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

#if canImport(AVFAudio) && !os(macOS)
import AVFAudio
#endif
import CoreVideo
import Foundation
@testable import LiveKit
import LiveKitUniFFI
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
#if canImport(UIKit)
import UIKit
#endif

/// End to end through the Rust core into a local OpenTelemetry collector: `livekit-server --dev`
/// and `otelcol-contrib --config Tests/LiveKitCoreTests/Telemetry/otelcol.yaml`, which writes every
/// OTLP request as a JSON line (CI starts both; see ci.yaml). The pipeline is process-wide, hence
/// one serialized story.
@Suite(.serialized, .tags(.e2e))
struct TelemetryTests {
    static let fileCollector = "http://127.0.0.1:4319"
    static let collectorOutput = URL(fileURLWithPath: "/tmp/livekit-telemetry-otlp.jsonl")

    /// One call and its aftermath: connect → publish (one publish fails on a denied microphone) →
    /// subscribe to first media → quick and full reconnect → app data → disconnect → opt-out.
    @Test(.enabled(if: collectorAvailable, "no LK_TELEMETRY_ENDPOINT and no collector on 127.0.0.1:4319"))
    func aCallFromConnectToOptOut() async throws {
        // The core reads the override when the pipeline starts: restart it pointed at the collector,
        // or at a backend of your own when `LK_TELEMETRY_ENDPOINT` is already set (see the PR).
        setenv("LK_TELEMETRY_ENDPOINT", Self.fileCollector, 0)
        Telemetry.configure()
        let start = UInt64(Date().timeIntervalSince1970 * 1e9)
        let marker = UUID().uuidString

        let call = try await makeCall(marker: marker)
        guard ProcessInfo.processInfo.environment["LK_TELEMETRY_ENDPOINT"] == Self.fileCollector else {
            await telemetryFlush() // nothing to read back: browse the traces instead
            print("telemetry e2e: publisher trace \(call.publisher), subscriber trace \(call.subscriber), " +
                "late joiner trace \(call.lateJoiner), manual subscriber trace \(call.manualSubscriber)")
            return
        }
        let otlp = try await Self.flushedRecords(since: start) { otlp in
            call.rooms.allSatisfy { trace in
                otlp.spans.contains { $0.traceId == trace && $0.name == "lk.connect" }
                    && otlp.logs.contains { $0.traceId == trace && $0.eventName == "lk.room.disconnected" }
            }
        }
        try expectSpans(otlp, of: call)
        try expectRejoin(otlp, of: call)
        try expectRecords(otlp, of: call, marker: marker)
        try await expectOptOut(marker: marker, since: start)
    }

    /// The Swift transport moves bytes: the collector's answer comes back untouched, and a
    /// credential-bearing request never follows a redirect to another origin.
    @Test func transportPassesAnswersThroughAndStaysOnItsOrigin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CollectorStub.self]
        let session = URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
        let transport = URLSessionTelemetryTransport(session: session)
        let request = ExportRequest(url: "http://collector.test/v1/logs", headers: ["Authorization": "Bearer token"], body: Data([1, 2, 3]))

        CollectorStub.answer.mutate { $0 = .success(.init(status: 429, headers: ["Retry-After": "7"], body: Data("quota".utf8))) }
        let throttled = try await transport.send(request: request)
        #expect(throttled.status == 429 && throttled.headers["Retry-After"] == "7" && throttled.body == Data("quota".utf8))

        CollectorStub.answer.mutate { $0 = .failure(URLError(.notConnectedToInternet)) }
        await #expect(throws: ExportError.self, "no answer is the transport's only error") {
            try await transport.send(request: request)
        }

        let task = try session.dataTask(with: URLRequest(url: #require(URL(string: "https://project.livekit.cloud/observability/client/logs/otlp/v0"))))
        for (target, follows) in [("https://project.livekit.cloud/other", true), ("https://elsewhere.test/v0", false),
                                  ("http://project.livekit.cloud/v0", false), ("https://project.livekit.cloud:8443/v0", false)]
        {
            let redirect = try URLRequest(url: #require(URL(string: target)))
            let followed = await withCheckedContinuation { continuation in
                SameOriginRedirects().urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(),
                                                 newRequest: redirect) { continuation.resume(returning: $0 != nil) }
            }
            #expect(followed == follows, "\(target)")
        }
    }
}

// MARK: - The story

extension TelemetryTests {
    /// The two Rooms' trace ids.
    struct Call {
        var publisher = "", subscriber = "", lateJoiner = "", manualSubscriber = ""
        var rooms: [String] { [publisher, subscriber, lateJoiner, manualSubscriber] }
    }

    func makeCall(marker: String) async throws -> Call {
        var call = Call()
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublish: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0], subscriber = rooms[1]
            call.publisher = try #require(publisher.telemetryScope?.traceId())
            call.subscriber = try #require(subscriber.telemetryScope?.traceId())
            // The app clearing its delegates leaves telemetry's own observer in place (subscribe asserts below).
            subscriber.removeAllDelegates()
            #expect(call.publisher.count == 32 && call.publisher != call.subscriber, "one trace per Room")

            // The public tracing API is untouched: the connect span still times the steps.
            let connect = try #require(publisher.connectSpan)
            #expect(Set(connect.entries.map(\.label)).isSuperset(of: ["ws_open", "signal", "join_recv", "pc_created", "room_connected"]))

            // App data: a correlation attribute on everything from now on (one set, one removed).
            publisher.setTelemetryAttribute("app.call_id", value: marker)
            subscriber.setTelemetryAttribute("app.call_id", value: marker)
            publisher.setTelemetryAttribute("app.removed", value: marker)
            publisher.setTelemetryAttribute("app.removed", value: nil)

            // Publish synthetic media: no capture device or permission in a headless run.
            let video = await LocalVideoTrack.createBufferTrack(name: "telemetry")
            let frames = try #require(video.capturer as? BufferCapturer).feedSyntheticFrames()
            defer { frames.cancel() }
            try await publisher.localParticipant.publish(videoTrack: video)
            let audio = try await publisher.localParticipant.publish(audioTrack: TestAudioTrack())
            // …and a microphone the user never allowed: a failed publish and a capture failure.
            await #expect(throws: LiveKitError.self) {
                try await publisher.localParticipant.publish(audioTrack: DeniedMicrophone())
            }

            let identity = try #require(publisher.localParticipant.identity)
            let remote = try #require(subscriber.remoteParticipants[identity])
            try await poll(timeout: 15, interval: 0.2, for: "subscriber has audio and video") {
                remote.audioTracks.first?.track != nil && remote.videoTracks.first?.track != nil
            }
            try await Task.sleep(nanoseconds: 3_000_000_000) // first media, at the core's 1 s polls

            // Late joiners: one finds the tracks already there (autoSubscribe), one subscribes by hand.
            (call.lateJoiner, call.manualSubscriber) = try await joinLate(publisher, publisherIdentity: identity)

            // The test microphone never sends a packet: unpublishing it ends its subscribe before first media.
            try await publisher.localParticipant.unpublish(publication: audio)

            publisher.log("\(marker) error", .error) // no ambient span: the Room's session
            publisher.emitTelemetryEvent("e2e.checkpoint", attributes: ["e2e.marker": marker])
            postDeviceChanges()

            try await publisher.debug_simulate(scenario: .quickReconnect)
            try await poll(timeout: 30, interval: 0.2, for: "quick reconnect settled") { publisher.connectionState == .connected }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await publisher.debug_simulate(scenario: .fullReconnect)
            try await poll(timeout: 30, interval: 0.2, for: "full reconnect settled") { publisher.connectionState == .connected }
            // The subscriber rejoins too: the server announces the video again at that join.
            try await subscriber.debug_simulate(scenario: .fullReconnect)
            try await poll(timeout: 30, interval: 0.2, for: "subscriber rejoined") { subscriber.connectionState == .connected }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return call
    }

    /// Two more subscribers join after the publish: one auto-subscribes to the tracks already
    /// there, one subscribes to the video by hand. Returns their trace ids.
    func joinLate(_ publisher: Room, publisherIdentity identity: Participant.Identity) async throws -> (String, String) {
        let late = try await Self.join(publisher, as: "late-joiner", autoSubscribe: true)
        let manual = try await Self.join(publisher, as: "manual-subscriber", autoSubscribe: false)
        do {
            let traces = try (#require(late.telemetryScope?.traceId()), #require(manual.telemetryScope?.traceId()))
            try await poll(timeout: 10, interval: 0.2, for: "the manual subscriber sees the video") {
                manual.remoteParticipants[identity]?.videoTracks.first != nil
            }
            let video = try #require(manual.remoteParticipants[identity]?.videoTracks.first as? RemoteTrackPublication)
            try await video.set(subscribed: true)
            try await Task.sleep(nanoseconds: 4_000_000_000) // first media, at the core's 1 s polls
            await late.disconnect()
            await manual.disconnect()
            return traces
        } catch {
            await late.disconnect()
            await manual.disconnect()
            throw error
        }
    }

    func expectSpans(_ otlp: OTLPFile, of call: Call) throws {
        let publisherSpans = otlp.spans.filter { $0.traceId == call.publisher }
        let subscriberSpans = otlp.spans.filter { $0.traceId == call.subscriber }

        // Connect: one span per Room with the required checkpoints; reconnects are their own spans.
        for spans in [publisherSpans, subscriberSpans] {
            let connects = spans.filter { $0.name == "lk.connect" }
            #expect(connects.count == 1, "one lk.connect per Room: \(connects.count)")
            let connect = try #require(connects.first)
            #expect(Set(connect.events).isSuperset(of: ["ws_open", "signal", "join_recv", "pc_created"]), "\(connect.events)")
            #expect(connect.attributes["lk.outcome"] == "ok" && connect.attributes["lk.connect.attempt"] == "1")
        }
        let reconnects = publisherSpans.filter { $0.name == "lk.reconnect" }
        #expect(reconnects.count == 2 && reconnects.allSatisfy { $0.attributes["lk.outcome"] == "ok" }, "\(reconnects.map(\.attributes))")
        #expect(reconnects.allSatisfy { $0.attributes["lk.reconnect.reason"] == "debug" && $0.events.contains { $0.hasPrefix("attempt 1 ") } },
                "\(reconnects.map(\.events))")

        // Publish: two tracks, one denied microphone; subscribe: intent → first media.
        let publishes = publisherSpans.filter { $0.name == "lk.publish" }
        #expect(publishes.filter { $0.attributes["lk.outcome"] == "ok" && $0.attributes["lk.track.sid"] != nil }.count >= 2, "\(publishes.map(\.attributes))")
        #expect(publishes.contains { $0.attributes["lk.outcome"] == "error" && $0.attributes["error.type"] == "LiveKitError.\(LiveKitErrorType.deviceAccessDenied.rawValue)" })
        #expect(otlp.logs.contains { $0.eventName == "lk.device.capture.failed" && $0.attributes["lk.device.capture.device"] == "microphone"
                && $0.attributes["lk.device.capture.reason"] == "permission_denied"
        })
        // The synthetic video reaches first media; the silent microphone, unpublished first, is cancelled.
        let subscribes = subscriberSpans.filter { $0.name == "lk.subscribe" }
        #expect(subscribes.contains { $0.attributes["lk.track.kind"] == "video" && $0.attributes["lk.outcome"] == "ok" && $0.events.contains("first_media") },
                "\(subscribes.map(\.events))")
        #expect(subscribes.contains { $0.attributes["lk.track.kind"] == "audio" && $0.attributes["lk.outcome"] == "cancelled" && !$0.events.contains("first_media") },
                "a track ended before first media: \(subscribes.map { ($0.attributes["lk.outcome"], $0.events) })")

        // Joining after the publish, or subscribing by hand: first media within the core's 1 s polls.
        for trace in [call.lateJoiner, call.manualSubscriber] {
            let video = otlp.spans.filter { $0.traceId == trace && $0.name == "lk.subscribe" && $0.attributes["lk.track.kind"] == "video" }
            #expect(video.contains { $0.attributes["lk.outcome"] == "ok" && $0.events.contains("first_media") && $0.seconds < 10 },
                    "\(video.map { ($0.events, $0.seconds) })")
        }
        // The late joiner wanted the tracks already in the Room from the moment it connected.
        let lateConnect = try #require(otlp.spans.first { $0.traceId == call.lateJoiner && $0.name == "lk.connect" })
        #expect(otlp.spans.contains { $0.traceId == call.lateJoiner && $0.name == "lk.subscribe" && $0.start <= lateConnect.end },
                "the subscribe intent starts at join")
    }

    /// After a full reconnect the intent starts at the rejoin, not at the later subscription.
    func expectRejoin(_ otlp: OTLPFile, of call: Call) throws {
        let rejoin = try #require(otlp.spans.first { $0.traceId == call.subscriber && $0.name == "lk.reconnect" })
        let resubscribed = otlp.spans.filter { $0.traceId == call.subscriber && $0.name == "lk.subscribe" && $0.start >= rejoin.start }
        #expect(resubscribed.contains { span in span.eventTimes["subscribed"].map { $0 > span.start + 1_000_000 } ?? false },
                "\(resubscribed.map { ($0.start, $0.eventTimes) })")
    }

    func expectRecords(_ otlp: OTLPFile, of call: Call, marker: String) throws {
        let mine = otlp.logs.filter { [call.publisher, call.subscriber].contains($0.traceId) }

        // RTC windows from one report per peer connection, each track in its direction.
        // (No inbound audio: the test microphone never sends a packet.)
        let windows = mine.filter { $0.eventName == "lk.rtc.stats.sample" }
        for (trace, kind, direction) in [(call.publisher, "audio", "outbound"), (call.publisher, "video", "outbound"), (call.subscriber, "video", "inbound")] {
            #expect(windows.contains { $0.traceId == trace && $0.attributes["lk.track.kind"] == kind && $0.attributes["lk.track.direction"] == direction },
                    "\(direction) \(kind) window")
        }

        // App data: the event, the attribute on the Room's records after it was set, never the removed one.
        #expect(mine.contains { $0.eventName == "custom.e2e.checkpoint" && $0.attributes["e2e.marker"] == marker && $0.attributes["app.call_id"] == marker })
        #expect(mine.contains { $0.body == "\(marker) error" && $0.traceId == call.publisher && $0.spanId.isEmpty && $0.severity >= 17 },
                "an SDK error lands in its Room's trace")
        #expect(windows.allSatisfy { $0.attributes["app.call_id"] == marker }, "windows carry the correlation attribute")
        #expect(!otlp.logs.contains { $0.attributes["app.removed"] != nil })

        // The session ends once per Room, never on a reconnect.
        let ended = mine.filter { $0.eventName == "lk.room.disconnected" }
        #expect(ended.count == 2 && ended.allSatisfy { $0.attributes["lk.disconnect.reason"] == "client_initiated" }, "\(ended.map(\.attributes))")

        // Device: the state's initial values, and what this platform can post.
        var device = ["lk.device.thermal.changed", "lk.device.memory.changed", "lk.device.network.changed", "lk.device.low_power.changed"]
        #if os(iOS) || os(tvOS) || os(visionOS)
        device += ["lk.device.audio.interruption", "lk.device.audio_route.changed", "lk.device.app_state.changed"]
        #endif
        for event in device {
            #expect(otlp.logs.contains { $0.eventName == event }, "\(event)")
        }
        #expect(otlp.logs.filter(\.eventName.isEmpty).allSatisfy { $0.severity >= 13 }, "log records are warnings and errors only")
        let stats = try #require(telemetryStats())
        #expect(stats.dropped == 0 && stats.cachedBatches == 0, "the whole call shipped: \(telemetryDiagnostics())")
    }

    func expectOptOut(marker: String, since start: UInt64) async throws {
        // Opt-out: what was not yet sent is deleted, nothing is collected afterwards.
        let pending = "\(marker) pending"
        let room = Room()
        room.emitTelemetryEvent(pending)
        // A connected Room, kept alive, publishing: its stats polling stops when the call returns.
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
            let connected = rooms[0]
            let video = await LocalVideoTrack.createBufferTrack(name: "opt-out")
            let frames = try #require(video.capturer as? BufferCapturer).feedSyntheticFrames()
            defer { frames.cancel() }
            try await connected.localParticipant.publish(videoTrack: video)
            let rtc = try #require(connected.rtcTelemetry)
            let scope = try #require(connected.telemetryScope)
            #expect(rtc.isPolling)
            // Two polls caught at the boundaries: one about to request getStats(), one about to submit.
            let beforeRequest = Pause(at: .request), beforeSubmit = Pause(at: .submit)
            let requesting = Task { await Telemetry.$beforeGate.withValue(beforeRequest.hook) { await connected.recordPeerStats(into: scope) } }
            let submitting = Task { await Telemetry.$beforeGate.withValue(beforeSubmit.hook) { await connected.recordPeerStats(into: scope) } }
            await beforeRequest.reached()
            await beforeSubmit.reached()
            LiveKitSDK.disableTelemetry()
            beforeRequest.resume()
            beforeSubmit.resume()
            let caughtRequesting = await requesting.value, caughtSubmitting = await submitting.value
            #expect(caughtRequesting.answered == 0 && caughtRequesting.submitted == 0, "no getStats() starts after the opt-out")
            #expect(caughtSubmitting.answered == 1 && caughtSubmitting.submitted == 0, "no report is submitted after the opt-out")
            #expect(!rtc.isPolling, "the poll loop is gone")
            rtc.poll(connected)
            #expect(!rtc.isPolling, "and nothing restarts it")
        }
        #expect(Room().telemetryScope == nil, "a Room created after the opt-out collects nothing")
        try await poll(timeout: 5, interval: 0.1, for: "the pipeline is gone") { telemetryScope() == nil }
        try await Task.sleep(nanoseconds: 2_000_000_000) // anything left would have arrived by now
        let after = try await Self.flushedRecords(since: start)
        #expect(!after.logs.contains { $0.eventName == "custom.\(pending)" }, "an unsent event is deleted, never uploaded")
        let cached = try FileManager.default.contentsOfDirectory(atPath: #require(Telemetry.storageDirectory).path)
        #expect(cached.isEmpty, "the on-disk cache is purged: \(cached)")
    }
}

// MARK: - Helpers

extension TelemetryTests {
    /// A collector to talk to: a backend named by `LK_TELEMETRY_ENDPOINT`, or the local one.
    static var collectorAvailable: Bool {
        if ProcessInfo.processInfo.environment["LK_TELEMETRY_ENDPOINT"] != nil { return true }
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(4319).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// A subscriber that joins `publisher`'s Room once its tracks are there.
    static func join(_ publisher: Room, as identity: String, autoSubscribe: Bool) async throws -> Room {
        let room = Room(connectOptions: ConnectOptions(autoSubscribe: autoSubscribe))
        let token = try TestEnvironment.liveKitServerToken(for: #require(publisher.name), identity: identity, canPublish: false,
                                                           canPublishData: false, canPublishSources: [], canSubscribe: true)
        try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: token)
        return room
    }

    /// Ships what the core holds and reads back what the collector wrote since `start`, waiting
    /// (up to 15 s) until `complete` holds: the collector writes each request as it arrives.
    static func flushedRecords(since start: UInt64, until complete: (OTLPFile) -> Bool = { _ in true }) async throws -> OTLPFile {
        await telemetryFlush()
        var otlp = try OTLPFile(url: collectorOutput, since: start)
        for _ in 0 ..< 30 where !complete(otlp) {
            try await Task.sleep(nanoseconds: 500_000_000)
            otlp = try OTLPFile(url: collectorOutput, since: start)
        }
        return otlp
    }

    /// Posts the OS notifications a simulator or host never sends on its own.
    func postDeviceChanges() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let center = NotificationCenter.default
        center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.override.rawValue])
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }
}
