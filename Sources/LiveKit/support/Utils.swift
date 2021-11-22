import Foundation
import WebRTC

typealias DebouncFunc = () -> Void

class Utils {

    internal static func buildErrorDescription(_ key: String, _ message: String? = nil) -> String {
        if let message = message {
            return "\(key) (\(message))"
        }
        return key
    }

    internal static func buildUrl(
        _ url: String,
        _ token: String,
        options: ConnectOptions? = nil,
        reconnect: Bool = false,
        validate: Bool = false,
        forceSecure: Bool = false
    ) throws -> URL {

        // use default options if nil
        let options = options ?? ConnectOptions()

        let parsedUrl = URL(string: url)

        guard let parsedUrl = parsedUrl else {
            throw InternalError.parse("Failed to parse url")
        }

        let components = URLComponents(url: parsedUrl, resolvingAgainstBaseURL: false)

        guard var builder = components else {
            throw InternalError.parse("Failed to parse url components")
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
            URLQueryItem(name: "protocol", value: options.protocolVersion.description),
            URLQueryItem(name: "sdk", value: "ios"),
            URLQueryItem(name: "version", value: "0.5")
        ]

        if reconnect {
            queryItems.append(URLQueryItem(name: "reconnect", value: "1"))
        }

        if options.autoSubscribe {
            queryItems.append(URLQueryItem(name: "auto_subscribe", value: "1"))
        }

        builder.queryItems = queryItems

        guard let builtUrl = builder.url else {
            throw InternalError.convert("Failed to convert components to url \(builder)")
        }

        return builtUrl
    }

    static func createDebounceFunc(wait: TimeInterval,
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

    static func computeEncodings(
        dimensions: Dimensions?,
        publishOptions: LocalVideoTrackPublishOptions?
    ) -> [RTCRtpEncodingParameters]? {

        let publishOptions = publishOptions ?? LocalVideoTrackPublishOptions()

        var encodingF: VideoEncoding? = nil
        var encodingH: VideoEncoding? = nil
        var encodingQ: VideoEncoding? = nil
        
        var activateH = true
        var activateQ = true
        
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
                // deactivate Q if dimensions are too small
                activateQ = false
            }
        }

        // if simulcast is enabled, always add "h" and "f" encoding parameters
        // but keep it active = false if dimension is too small
        return publishOptions.simulcast ? [
            RTCRtpEncodingParameters(rid: "q", encoding: encodingQ, scaleDown: 4, active: activateQ),
            RTCRtpEncodingParameters(rid: "h", encoding: encodingH, scaleDown: 2, active: activateH),
            RTCRtpEncodingParameters(rid: "f", encoding: encodingF)
        ] : [
            RTCRtpEncodingParameters(rid: "q", encoding: encodingF),
        ]
    }
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
