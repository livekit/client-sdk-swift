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
    internal var reconnect: Bool?

    public init(url: String, token: String, autoSubscribe: Bool = true) {
        self.url = url
        self.accessToken = token
        self.autoSubscribe = autoSubscribe
    }
}
