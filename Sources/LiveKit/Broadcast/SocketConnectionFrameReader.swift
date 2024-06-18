/*
 * Copyright 2024 LiveKit
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

import CoreImage
import CoreVideo
import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

private class Message {
    // Initializing a CIContext object is costly, so we use a singleton instead
    static let imageContextVar: CIContext? = {
        var imageContext = CIContext(options: nil)
        return imageContext
    }()

    var imageBuffer: CVImageBuffer?
    var didComplete: ((_ success: Bool, _ message: Message) -> Void)?
    var imageOrientation: CGImagePropertyOrientation = .up
    private var framedMessage: CFHTTPMessage?

    init() {}

    func appendBytes(buffer: [UInt8], length: Int) -> Int {
        if framedMessage == nil {
            framedMessage = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, false).takeRetainedValue()
        }

        guard let framedMessage else {
            return -1
        }

        CFHTTPMessageAppendBytes(framedMessage, buffer, length)
        if !CFHTTPMessageIsHeaderComplete(framedMessage) {
            return -1
        }

        guard let contentLengthStr = CFHTTPMessageCopyHeaderFieldValue(framedMessage, "Content-Length" as CFString)?.takeRetainedValue(),
              let body = CFHTTPMessageCopyBody(framedMessage)?.takeRetainedValue()
        else {
            return -1
        }

        let contentLength = Int(CFStringGetIntValue(contentLengthStr))
        let bodyLength = CFDataGetLength(body)

        let missingBytesCount = contentLength - bodyLength
        if missingBytesCount == 0 {
            let success = unwrapMessage(framedMessage)
            didComplete?(success, self)

            self.framedMessage = nil
        }

        return missingBytesCount
    }

    private func imageContext() -> CIContext? {
        Message.imageContextVar
    }

    private func unwrapMessage(_ framedMessage: CFHTTPMessage) -> Bool {
        guard let widthStr = CFHTTPMessageCopyHeaderFieldValue(framedMessage, "Buffer-Width" as CFString)?.takeRetainedValue(),
              let heightStr = CFHTTPMessageCopyHeaderFieldValue(framedMessage, "Buffer-Height" as CFString)?.takeRetainedValue(),
              let imageOrientationStr = CFHTTPMessageCopyHeaderFieldValue(framedMessage, "Buffer-Orientation" as CFString)?.takeRetainedValue(),
              let messageData = CFHTTPMessageCopyBody(framedMessage)?.takeRetainedValue()
        else {
            return false
        }

        let width = Int(CFStringGetIntValue(widthStr))
        let height = Int(CFStringGetIntValue(heightStr))
        imageOrientation = CGImagePropertyOrientation(rawValue: UInt32(CFStringGetIntValue(imageOrientationStr))) ?? .up

        // Copy the pixel buffer
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &imageBuffer)
        if status != kCVReturnSuccess {
            logger.log(level: .warning, "CVPixelBufferCreate failed")
            return false
        }

        copyImageData(messageData as Data, to: imageBuffer)

        return true
    }

    private func copyImageData(_ data: Data?, to pixelBuffer: CVPixelBuffer?) {
        if let pixelBuffer {
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
        }

        var image: CIImage?
        if let data {
            image = CIImage(data: data)
        }
        if let image, let pixelBuffer {
            imageContext()?.render(image, to: pixelBuffer)
        }

        if let pixelBuffer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
    }
}

class SocketConnectionFrameReader: NSObject {
    private static let kMaxReadLength = 10 * 1024
    private var readLength = 0

    private var _connection: BroadcastServerSocketConnection?
    private var connection: BroadcastServerSocketConnection? {
        get { _connection }
        set {
            if _connection != newValue {
                _connection?.close()
                _connection = newValue
            }
        }
    }

    private var message: Message?
    var didCapture: ((CVPixelBuffer, RTCVideoRotation) -> Void)?

    override init() {}

    func startCapture(with connection: BroadcastServerSocketConnection) {
        self.connection = connection
        message = nil

        if !connection.open() {
            stopCapture()
        }
    }

    func stopCapture() {
        connection?.close()
        connection = nil
    }

    // MARK: Private Methods

    func readBytes(from stream: InputStream) {
        if !(stream.hasBytesAvailable) {
            return
        }

        if message == nil {
            message = Message()
            readLength = SocketConnectionFrameReader.kMaxReadLength

            weak var weakSelf = self
            message?.didComplete = { success, message in
                if success {
                    weakSelf?.didCaptureVideoFrame(message.imageBuffer, with: message.imageOrientation)
                }

                weakSelf?.message = nil
            }
        }

        guard let msg = message
        else {
            return
        }

        var buffer = [UInt8](repeating: 0, count: readLength)
        let numberOfBytesRead = stream.read(&buffer, maxLength: readLength)
        if numberOfBytesRead < 0 {
            logger.log(level: .debug, "error reading bytes from stream")
            return
        }

        readLength = msg.appendBytes(buffer: buffer, length: numberOfBytesRead)
        if readLength == -1 || readLength > SocketConnectionFrameReader.kMaxReadLength {
            readLength = SocketConnectionFrameReader.kMaxReadLength
        }
    }

    func didCaptureVideoFrame(
        _ pixelBuffer: CVPixelBuffer?,
        with orientation: CGImagePropertyOrientation
    ) {
        guard let pixelBuffer else {
            return
        }

        var rotation: RTCVideoRotation
        switch orientation {
        case .left:
            rotation = ._90
        case .down:
            rotation = ._180
        case .right:
            rotation = ._270
        default:
            rotation = ._0
        }

        didCapture?(pixelBuffer, rotation)
    }
}

extension SocketConnectionFrameReader: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            logger.log(level: .debug, "server stream open completed")
        case .hasBytesAvailable:
            readBytes(from: aStream as! InputStream)
        case .endEncountered:
            logger.log(level: .debug, "server stream end encountered")
            stopCapture()
        case .errorOccurred:
            logger.log(level: .debug, "server stream error encountered: \(aStream.streamError?.localizedDescription ?? "")")
        default:
            break
        }
    }
}
