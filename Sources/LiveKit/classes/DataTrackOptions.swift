//
//  DataTrackOptions.swift
//
//
//  Created by Russell D'Sa on 1/31/21.
//

import Foundation

public typealias DataTrackOptionsBuilderBlock = (inout DataTrackOptions) -> Void

public struct DataTrackOptions {
    public var ordered: Bool = true
    public var maxPacketLifeTime: Int32 = -1
    public var maxRetransmits: Int32 = -1
    public var name: String

    public static func options(name: String) -> DataTrackOptions {
        return DataTrackOptions(name: name)
    }

    public static func options(name: String, block: DataTrackOptionsBuilderBlock) -> DataTrackOptions {
        var options = DataTrackOptions(name: name)
        block(&options)
        return options
    }
}
