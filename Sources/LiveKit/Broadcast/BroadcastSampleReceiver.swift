/*
 * Copyright 2025 LiveKit
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
import CoreImage

/// Receive samples produced by the broadcast extension.
final class BroadcastSampleReceiver {
    
    private let dataReceiver: SocketDataReceiver
    
    var didEnd: (() -> Void)?
    var didCaptureImage: ((CVImageBuffer, VideoRotation) -> Void)?
    
    init?(socketPath: String) {
        dataReceiver = SocketDataReceiver()
        guard let listener = SocketListener(filePath: socketPath, streamDelegate: dataReceiver) else {
            return
        }
        dataReceiver.didReceive = { [weak self] data in
            self?.decodeMessage(data)
        }
        dataReceiver.didEnd = { [weak self] in
            self?.didEnd?()
        }
        dataReceiver.start(with: listener)
    }
    
    private func decodeMessage(_ data: Data) {
        do {
            let message = try BroadcastMessage(transportEncoded: data)
            switch message {
            case .imageSample(let sample):
                let imageBuffer = try sample.toImageBuffer()
                didCaptureImage?(imageBuffer, VideoRotation(sample.orientation))
            }
        } catch {
            logger.debug("Failed to broadcast message: \(error)")
        }
    }

    func stop() {
        dataReceiver.stop()
    }
}

fileprivate extension VideoRotation {
    init(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .left: self = ._90
        case .down: self = ._180
        case .right: self = ._270
        default: self = ._0
        }
    }
}
