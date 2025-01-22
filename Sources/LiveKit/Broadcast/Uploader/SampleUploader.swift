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

#if os(iOS)

import Foundation

private enum Constants {
    static let bufferMaxLength = 10240
}

class SampleUploader {
    @Atomic private var isReady = false
    private var connection: BroadcastUploadSocketConnection

    private var dataToSend: Data?
    private var byteIndex = 0

    private let serialQueue: DispatchQueue

    init(connection: BroadcastUploadSocketConnection) {
        self.connection = connection
        serialQueue = DispatchQueue(label: "io.livekit.broadcast.sampleUploader")

        setupConnection()
    }

    @discardableResult func send(_ data: Data) -> Bool {
        guard isReady else {
            return false
        }

        isReady = false

        dataToSend = data
        byteIndex = 0

        serialQueue.async { [weak self] in
            self?.sendDataChunk()
        }

        return true
    }
}

private extension SampleUploader {
    func setupConnection() {
        connection.didOpen = { [weak self] in
            self?.isReady = true
        }
        connection.streamHasSpaceAvailable = { [weak self] in
            self?.serialQueue.async {
                if let success = self?.sendDataChunk() {
                    self?.isReady = !success
                }
            }
        }
    }

    @discardableResult func sendDataChunk() -> Bool {
        guard let dataToSend else {
            return false
        }

        var bytesLeft = dataToSend.count - byteIndex
        var length = bytesLeft > Constants.bufferMaxLength ? Constants.bufferMaxLength : bytesLeft

        length = dataToSend[byteIndex ..< (byteIndex + length)].withUnsafeBytes {
            guard let ptr = $0.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }

            return connection.writeToStream(buffer: ptr, maxLength: length)
        }

        if length > 0 {
            byteIndex += length
            bytesLeft -= length

            if bytesLeft == 0 {
                self.dataToSend = nil
                byteIndex = 0
            }
        } else {
            logger.log(level: .debug, "writeBufferToStream failure")
        }

        return true
    }
}

#endif
