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

internal import LiveKitUniFFI
internal import LiveKitWebRTC
import Foundation

/// The open source platform for real-time communication.
///
/// See [LiveKit's Online Docs](https://docs.livekit.io/) for more information.
///
/// Comments are written in [DocC](https://developer.apple.com/documentation/docc) compatible format.
/// With Xcode 13 and above you can build documentation right into your Xcode documentation viewer by chosing
/// **Product** >  **Build Documentation** from Xcode's menu.
///
/// Download the [Multiplatform SwiftUI Example](https://github.com/livekit/multiplatform-swiftui-example)
/// to try out the features.
@objcMembers
public class LiveKitSDK: NSObject, Loggable {
    override private init() {}

    @objc(sdkVersion)
    public static let version = "2.17.0"
    static let ffiVersion = buildVersion()

    fileprivate struct State {
        var logger: any Logger = OSLogger()
        var tracing: any Tracing = LoggingTracer()
    }

    fileprivate static let state = StateSync(State())

    /// Set a custom ``Tracing`` implementation to capture operation timing.
    ///
    /// The default ``LoggingTracer`` logs completed spans at debug level.
    /// Provide a custom implementation to capture timing data
    /// programmatically (e.g., for benchmarks).
    ///
    /// - Note: This method must be called before any Room operations
    /// e.g. in the `App.init()` or `AppDelegate/SceneDelegate`
    public static func setTracing(_ tracing: any Tracing) {
        state.mutate { $0.tracing = tracing }
    }

    /// Set a custom logger for the SDK
    /// - Note: This method must be called before any other logging is done
    /// e.g. in the `App.init()` or `AppDelegate/SceneDelegate`
    public static func setLogger(_ logger: any Logger) {
        state.mutate { $0.logger = logger }
    }

    /// Adjust the minimum log level for the default `OSLogger`
    /// - Note: This method must be called before any other logging is done
    /// e.g. in the `App.init()` or `AppDelegate/SceneDelegate`
    public static func setLogLevel(_ level: LogLevel) {
        setLogger(OSLogger(minLevel: level))
    }

    /// Disable logging for the SDK
    /// - Note: This method must be called before any other logging is done
    /// e.g. in the `App.init()` or `AppDelegate/SceneDelegate`
    public static func disableLogging() {
        setLogger(DisabledLogger())
    }

    @available(*, deprecated, renamed: "setLogLevel")
    public static func setLoggerStandardOutput() {
        setLogLevel(.debug)
    }

    /// Whether WARP is opted into for this process. See ``setWARPEnabled(_:)``.
    public static var isWARPEnabled: Bool {
        RTC.pcFactoryState.isWARPEnabled
    }

    /// Opt into WARP (WebRTC Abridged Roundtrip Protocol,
    /// [draft-uberti-tsvwg-warp](https://www.ietf.org/archive/id/draft-uberti-tsvwg-warp-00.html)),
    /// which shortens the WebRTC connection setup from ~6 round trips to ~2.
    ///
    /// The part of it the SDK turns on is the DTLS handshake carried inside the ICE STUN binding
    /// exchange (libwebrtc's `WebRTC-IceHandshakeDtls` field trial), so DTLS and ICE negotiate in
    /// parallel instead of one after the other. Rooms connected afterwards also mark their outgoing
    /// packets with DSCP, as ``ConnectOptions/isDscpEnabled`` does.
    ///
    /// ```swift
    /// LiveKitSDK.setWARPEnabled(true)
    ///
    /// let room = Room()
    /// try await room.connect(url: url, token: token)
    /// ```
    ///
    /// Can be called at any point, including after a ``Room`` has connected: the setting is read
    /// when a peer connection is created, so it applies to every room connected afterwards and
    /// leaves the ones already connected as they were negotiated. Call it before ``Room/connect(url:token:connectOptions:roomOptions:)``
    /// for it to take effect on that connection.
    ///
    /// - Note: The setting is process-global, not per ``Room``, and it replaces libwebrtc's global
    ///   field trial string — an app that sets its own trials through
    ///   `LKRTCInitFieldTrialDictionary` should set them again afterwards.
    /// - Note: A peer that does not implement the piggybacked handshake negotiates the standard
    ///   way, so enabling this does not break connections to servers without WARP support.
    /// - SeeAlso: ``ConnectOptions/isDscpEnabled``
    public static func setWARPEnabled(_ enabled: Bool) {
        RTC.pcFactoryState.mutate { $0.isWARPEnabled = enabled }
        RTC.applyFieldTrials(isWARPEnabled: enabled)
    }

    /// Notify the SDK to start initializing for faster connection/publishing later on. This is non-blocking.
    public static func prepare() {
        // TODO: Add RTC related initializations
        DeviceManager.prepare()
    }
}

// Lazily initialized to the first logger
let sharedLogger = LiveKitSDK.state.logger

// Lazily initialized to the first tracing
let sharedTracing = LiveKitSDK.state.tracing
