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

internal import LiveKitWebRTC

enum OS {
    case macOS
    case iOS
    case visionOS
    case tvOS
}

extension OS: CustomStringConvertible {
    var description: String {
        switch self {
        case .macOS: "macOS"
        case .iOS: "iOS"
        case .visionOS: "visionOS"
        case .tvOS: "tvOS"
        }
    }
}

func format(bps: UInt64) -> String {
    let bpsDivider: Double = 1000
    let ordinals = ["", "K", "M", "G", "T", "P", "E"]

    var rate = Double(bps)
    var ordinal = 0

    while rate > bpsDivider {
        rate /= bpsDivider
        ordinal += 1
    }

    return String(rate.rounded(to: 2)) + ordinals[ordinal] + "bps"
}

class Utils: Loggable {
    private static let processInfo = ProcessInfo()

    /// Returns current OS.
    static func os() -> OS {
        #if os(iOS)
        .iOS
        #elseif os(macOS)
        .macOS
        #elseif os(visionOS)
        .visionOS
        #elseif os(tvOS)
        .tvOS
        #endif
    }

    /// Returns os version as a string.
    /// format: `12.1`, `15.3.1`, `15.0.1`
    static func osVersionString() -> String {
        let osVersion = processInfo.operatingSystemVersion
        var versions = [osVersion.majorVersion]
        if osVersion.minorVersion != 0 || osVersion.patchVersion != 0 {
            versions.append(osVersion.minorVersion)
        }
        if osVersion.patchVersion != 0 {
            versions.append(osVersion.patchVersion)
        }
        return versions.map { String($0) }.joined(separator: ".")
    }

    /// Returns a model identifier.
    /// format: `MacBookPro18,3`, `iPhone13,3` or `iOSSimulator,arm64`
    static func modelIdentifier() -> String? {
        #if os(iOS) || os(visionOS) || os(tvOS)
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
        #elseif os(macOS)
        let mainPort: mach_port_t = if #available(macOS 12.0, *) {
            kIOMainPortDefault
        } else {
            0 // kIOMainPortDefault (macOS 12+) is a synonym for the NULL default port
        }
        let service = IOServiceGetMatchingService(mainPort,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }

        guard let modelData = IORegistryEntryCreateCFProperty(service,
                                                              "model" as CFString,
                                                              kCFAllocatorDefault,
                                                              0).takeRetainedValue() as? Data
        else {
            return nil
        }

        return modelData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> String? in
            guard let cString = pointer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return String(cString: cString)
        }
        #endif
    }
}

extension Collection {
    /// Returns the element at the specified index if it is within bounds, otherwise nil.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension MutableCollection {
    subscript(safe index: Index) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set {
            if let newValue, indices.contains(index) {
                self[index] = newValue
            }
        }
    }
}

extension HTTPURLResponse {
    var isStatusCodeOK: Bool {
        (200 ..< 300).contains(statusCode)
    }
}

func computeAttributesDiff(oldValues: [String: String], newValues: [String: String]) -> [String: String] {
    let allKeys = Set(oldValues.keys).union(newValues.keys)
    var diff = [String: String]()

    for key in allKeys where oldValues[key] != newValues[key] {
        diff[key] = newValues[key] ?? ""
    }

    return diff
}
