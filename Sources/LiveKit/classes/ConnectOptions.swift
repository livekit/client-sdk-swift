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
    public var url: String
    var reconnect: Bool?
    
    public init(url: String, token accessToken: String) {
        self.url = url
        self.accessToken = accessToken
    }
}
