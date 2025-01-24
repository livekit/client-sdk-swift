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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

class SocketDataReceiver: NSObject {
    
    private static let kMaxReadLength = 10 * 1024
    
    /// Limits the number of bytes read from the stream when set.
    private var byteDemand: Int? {
        didSet {
            guard let byteDemand, 1...Self.kMaxReadLength ~= byteDemand else {
                byteDemand = nil
                return
            }
        }
    }

    private var _connection: SocketListener?
    private var connection: SocketListener? {
        get { _connection }
        set {
            if _connection != newValue {
                _connection?.close()
                _connection = newValue
            }
        }
    }

    private var reader = HTTPMessageReader()
    
    var didReceive: ((Data) -> Void)?
    var didEnd: (() -> Void)?

    override init() {}

    func start(with connection: SocketListener) {
        self.connection = connection
        guard connection.open() else {
            stop()
            return
        }
    }

    func stop() {
        connection?.close()
        connection = nil
    }

    // MARK: Private Methods

    private func readBytes(from stream: InputStream) {
        guard let data = stream.read(maxLength: byteDemand ?? Self.kMaxReadLength) else {
            logger.debug("Error reading bytes from stream")
            return
        }
        do {
            let completeMessage = try reader.append(data)
            handle(message: completeMessage)
            byteDemand = nil
        } catch {
            switch error {
            case .incomplete(let remainingBytes):
                guard let remainingBytes else { return }
                byteDemand = remainingBytes
            default:
                logger.debug("Failed to read HTTP message: \(error)")
            }
        }
    }

    private func handle(message: HTTPMessage) {
        guard let data = message.body else {
            logger.debug("Failed to get message data")
            return
        }
        didReceive?(data)
    }
}

fileprivate extension InputStream {
    func read(maxLength: Int) -> Data? {
        guard hasBytesAvailable else { return nil }
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let bytesRead = self.read(&buffer, maxLength: maxLength)
        guard bytesRead > 0 else {
            return nil
        }
        return Data(buffer.prefix(bytesRead))
    }
}

extension SocketDataReceiver: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            logger.log(level: .debug, "server stream open completed")
        case .hasBytesAvailable:
            readBytes(from: aStream as! InputStream)
        case .endEncountered:
            logger.log(level: .debug, "server stream end encountered")
            stop()
            didEnd?()
        case .errorOccurred:
            logger.log(level: .debug, "server stream error encountered: \(aStream.streamError?.localizedDescription ?? "")")
        default:
            break
        }
    }
}

#endif
