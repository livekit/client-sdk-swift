import Foundation

public struct ConnectOptions: Equatable {
    public var accessToken: String
    public var url: String
    public var autoSubscribe: Bool
    public var protocolVersion: ProtocolVersion

    public init(url: String,
                token: String,
                autoSubscribe: Bool = true,
                protocolVersion: ProtocolVersion = .v3) {

        self.accessToken = token
        self.url = url
        self.autoSubscribe = autoSubscribe
        self.protocolVersion = protocolVersion
    }
}

extension ConnectOptions {

    internal func buildUrl(
        reconnect: Bool = false,
        validate: Bool = false,
        forceSecure: Bool = false
    ) throws -> URL {

        let parsedUrl = URL(string: url)

        guard let parsedUrl = parsedUrl else {
            throw InternalError.parse("Failed to parse url")
        }

        let components = URLComponents(url: parsedUrl, resolvingAgainstBaseURL: false)

        guard var components = components else {
            throw InternalError.parse("Failed to parse url components")
        }

        let useSecure = parsedUrl.isSecure || forceSecure
        let httpScheme = useSecure ? "https" : "http"
        let wsScheme = useSecure ? "wss" : "ws"

        components.scheme = validate ? httpScheme : wsScheme
        components.path = validate ? "/validate" : "/rtc"

        var query = [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "protocol", value: protocolVersion.description),
            URLQueryItem(name: "sdk", value: "ios"),
            URLQueryItem(name: "version", value: "0.5"),
        ]

        if reconnect {
            query.append(URLQueryItem(name: "reconnect", value: "1"))
        }

        if autoSubscribe {
            query.append(URLQueryItem(name: "auto_subscribe", value: "1"))
        }

        components.queryItems = query

        guard let builtUrl = components.url else {
            throw InternalError.convert("Failed to convert components to url \(components)")
        }

        return builtUrl
    }
}
