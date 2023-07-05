/*
 * Copyright 2022 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import WebRTC

@objc
public class E2EEManager: NSObject, ObservableObject, Loggable {
    internal var room: Room?
    internal var enabled: Bool = false
    private let e2eeOptions: E2EEOptions
    var frameCryptors = [String: RTCFrameCryptor]()
    
    public init(e2eeOptions: E2EEOptions) {
        self.e2eeOptions = e2eeOptions
    }
    
    public func setup(room: Room){
        if(self.room != room) {
            cleanUp()
        }
        self.room = room
        self.room?.delegates.add(delegate: self)
        
    }
    
    public func cleanUp() {
        
    }
}

extension E2EEManager: RoomDelegate {
    
    public func room(_ room: Room, localParticipant: LocalParticipant, didPublish publication: LocalTrackPublication) {
        
    }
    
    public func room(_ room: Room, participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track: Track) {
        
    }
}
