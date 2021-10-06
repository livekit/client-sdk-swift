//
//  File.swift
//
//
//  Created by Russell D'Sa on 11/8/20.
//

import Foundation

public struct ConnectOptions {

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
