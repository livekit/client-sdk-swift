import Foundation
import WebRTC
import Promises

internal let videoRids = ["q", "h", "f"]

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

        guard let cString = modelData.withUnsafeBytes({ $0.baseAddress?.assumingMemoryBound(to: UInt8.self) }) else {
            return nil
        }

        return String(cString: cString)
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

    internal static func buildUrl(
        _ url: String,
        _ token: String,
        connectOptions: ConnectOptions? = nil,
        connectMode: ConnectMode = .normal,
        validate: Bool = false,
        forceSecure: Bool = false
    ) -> Promise<URL> {

        Promise(on: .sdk) { () -> URL in
            // use default options if nil
            let connectOptions = connectOptions ?? ConnectOptions()

            guard let parsedUrl = URL(string: url) else {
                throw InternalError.parse(message: "Failed to parse url")
            }

            let components = URLComponents(url: parsedUrl, resolvingAgainstBaseURL: false)

            guard var builder = components else {
                throw InternalError.parse(message: "Failed to parse url components")
            }

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

            if case .reconnect(let r) = connectMode,
               case .quick = r {
                // Only append "reconnect" for quick-reconnect
                queryItems.append(URLQueryItem(name: "reconnect", value: "1"))
            }

            if connectOptions.autoSubscribe {
                queryItems.append(URLQueryItem(name: "auto_subscribe", value: "1"))
            }

            if let publish = connectOptions.publish {
                queryItems.append(URLQueryItem(name: "publish", value: publish))
            }

            builder.queryItems = queryItems

            guard let builtUrl = builder.url else {
                throw InternalError.convert(message: "Failed to convert components to url \(builder)")
            }

            return builtUrl
        }
    }

    internal static func createDebounceFunc(wait: TimeInterval,
                                            onCreateWorkItem: ((DispatchWorkItem) -> Void)? = nil,
                                            fnc: @escaping @convention(block) () -> Void) -> DebouncFunc {
        var workItem: DispatchWorkItem?
        return {
            workItem?.cancel()
            workItem = DispatchWorkItem { fnc() }
            onCreateWorkItem?(workItem!)
            DispatchQueue.sdk.asyncAfter(deadline: .now() + wait, execute: workItem!)
        }
    }

    #if LK_COMPUTE_VIDEO_SENDER_PARAMETERS

    internal static func computeEncodings(
        dimensions: Dimensions?,
        publishOptions: VideoPublishOptions?,
        isScreenShare: Bool = false
    ) -> [RTCRtpEncodingParameters] {

        let publishOptions = publishOptions ?? VideoPublishOptions()
        let useSimulcast: Bool = !isScreenShare && publishOptions.simulcast
        let encoding: VideoEncoding? = isScreenShare ? publishOptions.screenShareEncoding : publishOptions.encoding

        guard (encoding != nil || useSimulcast), let dimensions = dimensions else {
            return []
        }

        // get suggested presets for the dimensions
        let presets = dimensions.computeSuggestedPresets(isScreenShare: isScreenShare)

        let encoding2 = encoding ?? dimensions.computeSuggestedPreset(in: presets)

        guard useSimulcast else {
            return [Engine.createRtpEncodingParameters(encoding: encoding2)]
        }

        let lowPreset = presets[0]
        let midPreset = presets[safe: 1]
        let original = VideoParameters(dimensions: dimensions,
                                       encoding: encoding2)

        var l = [original]
        if dimensions.max >= 960, let midPreset = midPreset {
            l = [lowPreset, midPreset, original]
        } else if dimensions.max >= 500 {
            l = [lowPreset, original]
        }

        return dimensions.encodings(from: l)
    }

    internal static func videoLayersForEncodings(
        dimensions: Dimensions?,
        encodings: [RTCRtpEncodingParameters]?
    ) -> [Livekit_VideoLayer] {
        let trackWidth = dimensions?.width ?? 0
        let trackHeight = dimensions?.height ?? 0

        guard let encodings = encodings else {
            return [Livekit_VideoLayer.with {
                $0.width = UInt32(trackWidth)
                $0.height = UInt32(trackHeight)
                $0.quality = Livekit_VideoQuality.high
                $0.bitrate = 0
            }]
        }

        return encodings.map { encoding in
            let scaleDownBy = encoding.scaleResolutionDownBy?.doubleValue ?? 1.0

            var videoQuality: Livekit_VideoQuality
            switch encoding.rid ?? "" {
            case "f": videoQuality = Livekit_VideoQuality.high
            case "h": videoQuality = Livekit_VideoQuality.medium
            case "q": videoQuality = Livekit_VideoQuality.low
            default: videoQuality = Livekit_VideoQuality.UNRECOGNIZED(-1)
            }

            if videoQuality == Livekit_VideoQuality.UNRECOGNIZED(-1) && encodings.count == 1 {
                videoQuality = Livekit_VideoQuality.high
            }

            return Livekit_VideoLayer.with {
                $0.width = UInt32((Double(trackWidth) / scaleDownBy).rounded(.up))
                $0.height = UInt32((Double(trackHeight) / scaleDownBy).rounded(.up))
                $0.quality = videoQuality
                $0.bitrate = encoding.maxBitrateBps?.uint32Value ?? 0
            }
        }
    }
    #endif
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
