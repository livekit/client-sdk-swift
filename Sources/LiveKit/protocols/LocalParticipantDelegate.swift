//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/10/20.
//

import Foundation

public protocol LocalParticipantDelegate {
    func didPublishAudioTrack(track: LocalAudioTrack)
    func didFailToPublishAudioTrack(error: Error)
//    func localParticipant:didPublishDataTrack
//    func localParticipant:didFailToPublishDataTrack:withError
//    func localParticipant:didPublishVideoTrack
//    func localParticipant:didFailToPublishVideoTrack:withError
//    func localParticipant:networkQualityLevelDidChange
}
