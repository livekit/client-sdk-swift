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
import OSLog
internal import LiveKitWebRTC

let logger = OSLog(subsystem: "io.livekit.sdk", category: "LiveKit")

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
public class LiveKitSDK: NSObject {
    override private init() {}

    @objc(sdkVersion)
    public static let version = "2.8.1"

    struct State {
        var logHandler: LogHandler = OSLogHandler()
    }

    static let state = StateSync(State())

    @objc
    public enum LogLevel: Int, Sendable {
        case trace // drop?
        case debug
        case info
        case warning
        case error

        var osLogType: OSLogType {
            switch self {
            case .trace: .debug
            case .debug: .debug
            case .info: .info
            case .warning: .default
            case .error: .error
            }
        }

        var rtcLevel: LKRTCLoggingSeverity {
            switch self {
            case .trace: .verbose
            case .debug: .verbose
            case .info: .info
            case .warning: .warning
            case .error: .error
            }
        }
    }

    /// Adjust the global log level
    /// - Note: This must be called before initializing any other LiveKit SDK objects like `Room`
    /// e.g. in `App.init()` or `AppDelegate`/`SceneDelegate`.
    @objc
    public static func setLogLevel(_: LogLevel) {
//        state.mutate { $0.logLevel = level }
    }

    /// Enable debug logging
    /// - Note: This must be called before initializing any other LiveKit SDK objects like `Room`
    /// e.g. in `App.init()` or `AppDelegate`/`SceneDelegate`.
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
