import Foundation
import WebRTC
import Promises

typealias DebouncFunc = () -> Void

class Utils {

    internal static func buildUrl(
        _ url: String,
        _ token: String,
        connectOptions: ConnectOptions? = nil,
        reconnect: Bool = false,
        validate: Bool = false,
        forceSecure: Bool = false
    ) -> Promise<URL> {

        Promise { () -> URL in
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
                URLQueryItem(name: "version", value: LiveKit.version)
            ]

            if reconnect {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: workItem!)
        }
    }

    #if LK_COMPUTE_VIDEO_SENDER_PARAMETERS

    internal static func computeEncodings(
        dimensions: Dimensions?,
        publishOptions: VideoPublishOptions?
    ) -> [RTCRtpEncodingParameters]? {

        let publishOptions = publishOptions ?? VideoPublishOptions()

        var encodingF: VideoEncoding?
        var encodingH: VideoEncoding?
        var encodingQ: VideoEncoding?

        var activateF = true

        // only if dimensions are available, compute encodings
        if let dimensions = dimensions {
            // find presets array 16:9 or 4:3, always small to large order
            let presets = dimensions.computeSuggestedPresets()
            let presetIndexF = dimensions.computeSuggestedPresetIndex(in: presets)

            encodingF = presets[presetIndexF].encoding
            encodingH = encodingF
            encodingQ = encodingF

            // try to get a 1 step lower encoding preset
            if let e = presets[safe: presetIndexF - 1]?.encoding {
                encodingH = e
                encodingQ = e
            }

            // try to get a 2 step lower encoding preset
            if let e = presets[safe: presetIndexF - 2]?.encoding {
                encodingQ = e
            }

            if max(dimensions.width, dimensions.height) < 960 {
                // deactivate F if dimensions are too small
                activateF = false
            }
        }

        // if simulcast is enabled, always add "h" and "f" encoding parameters
        // but keep it active = false if dimension is too small
        return publishOptions.simulcast ? [
            Engine.createRtpEncodingParameters(rid: "q", encoding: encodingQ, scaleDown: activateF ? 4 : 2),
            Engine.createRtpEncodingParameters(rid: "h", encoding: encodingH, scaleDown: activateF ? 2 : 1),
            Engine.createRtpEncodingParameters(rid: "f", encoding: encodingF, scaleDown: 1, active: activateF)
        ] : [
            Engine.createRtpEncodingParameters(rid: "q", encoding: encodingF)
        ]
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

extension Collection {
    /// Returns the element at the specified index if it is within bounds, otherwise nil.
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

extension MutableCollection {
    subscript(safe index: Index) -> Element? {
        get {
            return indices.contains(index) ? self[index] : nil
        }
        set(newValue) {
            if let newValue = newValue, indices.contains(index) {
                self[index] = newValue
            }
        }
    }
}
