//
//  File.swift
//  
//
//  Created by Russell D'Sa on 11/8/20.
//

import Foundation

public typealias ConnectOptionsBuilderBlock = (inout ConnectOptions) -> Void

public struct ConnectOptions {
    private(set) var accessToken: String
    
    public var roomName: String?
    public var roomId: String?
    public var host: String = "localhost"
    public var isSecure: Bool = false
    public var rpcPrefix: String = "/twirp"
    
    init(token accessToken: String) {
        self.accessToken = accessToken
    }
    
    public static func options(token accessToken: String, block: ConnectOptionsBuilderBlock?) -> ConnectOptions {
        var options = ConnectOptions(token: accessToken)
        if let builderBlock = block {
            builderBlock(&options)
        }
        return options
    }
}
