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
import Promises

internal typealias DebouncFunc = () -> Void

internal enum OS {
    case macOS
    case iOS
}

extension OS: CustomStringConvertible {
    internal var description: String {
        switch self {
        case .macOS: return "macOS"
        case .iOS: return "iOS"
        }
    }
}

internal class Utils {

    private static let processInfo = ProcessInfo()

    /// Returns current OS.
    internal static func os() -> OS {
        #if os(macOS)
        .macOS
        #elseif os(iOS)
        .iOS
        #endif
    }

    /// Returns os version as a string.
    /// format: `12.1`, `15.3.1`, `15.0.1`
    internal static func osVersionString() -> String {
        let osVersion = processInfo.operatingSystemVersion
        var versions = [osVersion.majorVersion]
        if osVersion.minorVersion != 0 || osVersion.patchVersion != 0 {
            versions.append(osVersion.minorVersion)
        }
        if osVersion.patchVersion != 0 {
            versions.append(osVersion.patchVersion)
        }
        return versions.map({ String($0) }).joined(separator: ".")
    }

    /// Returns a model identifier.
    /// format: `MacBookPro18,3`, `iPhone13,3` or `iOSSimulator,arm64`
    internal static func modelIdentifier() -> String? {
        #if os(macOS)
        let service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }

        guard let modelData = IORegistryEntryCreateCFProperty(service,
                                                              "model" as CFString,
                                                              kCFAllocatorDefault,
                                                              0).takeRetainedValue() as? Data else {
            return nil
        }

        return modelData.withUnsafeBytes({ (pointer: UnsafeRawBufferPointer) -> String? in
            guard let cString = pointer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return String(cString: cString)
        })
        #elseif os(iOS)
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        // for simulator, the following codes are returned
        guard !["i386", "x86_64", "arm64"].contains(where: { $0 == identifier }) else {
            return "iOSSimulator,\(identifier)"
        }
        return identifier
        #endif
    }

    internal static func networkTypeString() -> String? {
        // wifi, wired, cellular, vpn, empty if not known
        guard let interface = ConnectivityListener.shared.activeInterfaceType() else {
            return nil
        }

        switch interface {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "wired"
        default: return nil
        }
    }

    internal static func buildUrl(
        _ url: String,
        _ token: String,
        connectOptions: ConnectOptions? = nil,
        reconnectMode: ReconnectMode? = nil,
        adaptiveStream: Bool,
        validate: Bool = false,
        forceSecure: Bool = false
    ) -> URL? {

        // use default options if nil
        let connectOptions = connectOptions ?? ConnectOptions()

        guard let parsedUrl = URL(string: url) else { return nil }

        let components = URLComponents(url: parsedUrl, resolvingAgainstBaseURL: false)

        guard var builder = components else { return nil }

        let useSecure = parsedUrl.isSecure || forceSecure
        let httpScheme = useSecure ? "https" : "http"
        let wsScheme = useSecure ? "wss" : "ws"
        let lastPathSegment = validate ? "validate" : "rtc"

        var pathSegments = parsedUrl.pathComponents
        // strip empty & slashes
        pathSegments.removeAll(where: { $0.isEmpty || $0 == "/" })

        // if already ending with `rtc` or `validate`
        // and is not a dir, remove it
        if !parsedUrl.hasDirectoryPath
            && !pathSegments.isEmpty
            && ["rtc", "validate"].contains(pathSegments.last!) {
            pathSegments.removeLast()
        }
        // add the correct segment
        pathSegments.append(lastPathSegment)

        builder.scheme = validate ? httpScheme : wsScheme
        builder.path = "/" + pathSegments.joined(separator: "/")

        var queryItems = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "protocol", value: connectOptions.protocolVersion.description),
            URLQueryItem(name: "sdk", value: "swift"),
            URLQueryItem(name: "version", value: LiveKit.version),
            // Additional client info
            URLQueryItem(name: "os", value: String(describing: os())),
            URLQueryItem(name: "os_version", value: osVersionString())
        ]

        if let modelIdentifier = modelIdentifier() {
            queryItems.append(URLQueryItem(name: "device_model", value: modelIdentifier))
        }

        if let network = networkTypeString() {
            queryItems.append(URLQueryItem(name: "network", value: network))
        }

        // only for quick-reconnect
        queryItems.append(URLQueryItem(name: "reconnect", value: .quick == reconnectMode ? "1" : "0"))
        queryItems.append(URLQueryItem(name: "auto_subscribe", value: connectOptions.autoSubscribe ? "1" : "0"))
        queryItems.append(URLQueryItem(name: "adaptive_stream", value: adaptiveStream ? "1" : "0"))

        if let publish = connectOptions.publishOnlyMode {
            queryItems.append(URLQueryItem(name: "publish", value: publish))
        }

        builder.queryItems = queryItems

        return builder.url
    }

    internal static func createDebounceFunc(on queue: DispatchQueue,
                                            wait: TimeInterval,
                                            onCreateWorkItem: ((DispatchWorkItem) -> Void)? = nil,
                                            fnc: @escaping @convention(block) () -> Void) -> DebouncFunc {
        var workItem: DispatchWorkItem?
        return {
            workItem?.cancel()
            workItem = DispatchWorkItem { fnc() }
            onCreateWorkItem?(workItem!)
            queue.asyncAfter(deadline: .now() + wait, execute: workItem!)
        }
    }

    internal static func computeEncodings(
        dimensions: Dimensions,
        publishOptions: VideoPublishOptions?,
        isScreenShare: Bool = false
    ) -> [RTCRtpEncodingParameters] {

        let publishOptions = publishOptions ?? VideoPublishOptions()
        let preferredEncoding: VideoEncoding? = isScreenShare ? publishOptions.screenShareEncoding : publishOptions.encoding
        let encoding = preferredEncoding ?? dimensions.computeSuggestedPreset(in: dimensions.computeSuggestedPresets(isScreenShare: isScreenShare))

        guard publishOptions.simulcast else {
            return [Engine.createRtpEncodingParameters(encoding: encoding, scaleDownBy: 1)]
        }

        let baseParameters = VideoParameters(dimensions: dimensions,
                                             encoding: encoding)

        // get suggested presets for the dimensions
        let preferredPresets = (isScreenShare ? publishOptions.screenShareSimulcastLayers : publishOptions.simulcastLayers)
        let presets = (!preferredPresets.isEmpty ? preferredPresets : baseParameters.defaultSimulcastLayers(isScreenShare: isScreenShare)).sorted { $0 < $1 }

        logger.log("Using presets: \(presets), count: \(presets.count) isScreenShare: \(isScreenShare)", type: Utils.self)

        let lowPreset = presets[0]
        let midPreset = presets[safe: 1]

        var resultPresets = [baseParameters]
        if dimensions.max >= 960, let midPreset = midPreset {
            resultPresets = [lowPreset, midPreset, baseParameters]
        } else if dimensions.max >= 480 {
            resultPresets = [lowPreset, baseParameters]
        }

        return dimensions.encodings(from: resultPresets)
    }
}

internal extension Collection {
    /// Returns the element at the specified index if it is within bounds, otherwise nil.
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

internal extension MutableCollection {
    subscript(safe index: Index) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set {
            if let newValue = newValue, indices.contains(index) {
                self[index] = newValue
            }
        }
    }
}
