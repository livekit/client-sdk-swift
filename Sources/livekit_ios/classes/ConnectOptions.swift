//
//  File.swift
//  
//
//  Created by Russell D'Sa on 11/8/20.
//

import Foundation

typealias ConnectOptionsBuilderBlock = (inout ConnectOptionsBuilder) -> Void

struct ConnectOptions {
    private var builder: ConnectOptionsBuilder
    var config: ConnectOptionsBuilder {
        return builder
    }
    
    init(token accessToken: String, block: ConnectOptionsBuilderBlock?) {
        builder = ConnectOptionsBuilder(accessToken)
        if let builderBlock = block {
            builderBlock(&builder)
        }
    }
}

struct ConnectOptionsBuilder {
    private(set) var accessToken: String
    var roomName: String = ""
    var host: String = ""
    var isSecure: Bool = false
    var port: UInt8 = 80
    
    init(_ accessToken: String) {
        self.accessToken = accessToken
    }
}
