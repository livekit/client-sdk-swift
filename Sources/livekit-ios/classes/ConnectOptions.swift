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
    
    init(_ accessToken: String) {
        self.accessToken = accessToken
    }
}
