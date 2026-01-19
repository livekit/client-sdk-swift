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
internal import LiveKitWebRTC
internal import LiveKitUniFFI

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
@objc
public class LiveKitSDK: NSObject, Loggable {
    override private init() {}

    @objc(sdkVersion)
    public static let version = "2.11.0"
    static let ffiVersion = buildVersion()

    fileprivate struct State {
        var logger: Logger = OSLogger()
    }

    fileprivate static let state = StateSync(State())

    /// Set a custom logger for the SDK
    /// - Note: This method must be called before any other logging is done
    /// e.g. in the `App.init()` or `AppDelegate/SceneDelegate`
    public static func setLogger(_ logger: Logger) {
        state.mutate { $0.logger = logger }
    }

    /// Adjust the minimum log level for the default `OSLogger`
    /// - Note: This method must be called before any other logging is done
    /// e.g. in the `App.init()` or `AppDelegate/SceneDelegate`
    @objc
    public static func setLogLevel(_ level: LogLevel) {
        setLogger(OSLogger(minLevel: level))
    }

    /// Disable logging for the SDK
    /// - Note: This method must be called before any other logging is done
    /// e.g. in the `App.init()` or `AppDelegate/SceneDelegate`
    @objc
    public static func disableLogging() {
        setLogger(DisabledLogger())
    }

    @available(*, deprecated, renamed: "setLogLevel")
    @objc
    public static func setLoggerStandardOutput() {
        setLogLevel(.debug)
    }

    /// Notify the SDK to start initializing for faster connection/publishing later on. This is non-blocking.
    @objc
    public static func prepare() {
        // TODO: Add RTC related initializations
        DeviceManager.prepare()
    }
}

// Lazily initialized to the first logger
let sharedLogger = LiveKitSDK.state.logger
