//
//  File.swift
//  
//
//  Created by Russell D'Sa on 11/8/20.
//

import Foundation

public typealias ConnectOptionsBuilderBlock = (inout ConnectOptionsBuilder) -> Void

public struct ConnectOptions {
    private var builder: ConnectOptionsBuilder
    var config: ConnectOptionsBuilder {
        return builder
    }
    
    public init(token accessToken: String, block: ConnectOptionsBuilderBlock?) {
        builder = ConnectOptionsBuilder(accessToken)
        if let builderBlock = block {
            builderBlock(&builder)
        }
    }
}

public struct ConnectOptionsBuilder {
    private(set) var accessToken: String
    public var roomName: String?
    public var roomId: String?
    public var host: String = "localhost"
    public var isSecure: Bool = false
    public var rtcPort: UInt32 = 80
    public var httpPort: UInt32 = 80
    public var rpcPrefix: String = "/twirp"
    
    init(_ accessToken: String) {
        self.accessToken = accessToken
    }
}
