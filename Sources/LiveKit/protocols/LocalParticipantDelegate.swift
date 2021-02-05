//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/10/20.
//

import Foundation

public protocol LocalParticipantDelegate: AnyObject {
    func didPublishAudioTrack(track: LocalAudioTrack)
    func didFailToPublishAudioTrack(error: Error)
    func didPublishVideoTrack(track: LocalVideoTrack)
    func didFailToPublishVideoTrack(error: Error)
    func didPublishDataTrack(track: LocalDataTrack)
//    func didFailToPublishDataTrack(error: Error)
//    func localParticipant:networkQualityLevelDidChange
}
