//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/30/20.
//

import Foundation

public protocol RemoteDataTrackDelegate {
    func didReceiveString(message: String, dataTrack: RemoteDataTrack)
    func didReceiveData(message: Data, dataTrack: RemoteDataTrack)
}
