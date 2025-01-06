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

#if canImport(ReplayKit)
import ReplayKit
#endif

private enum Constants {
    static let bufferMaxLength = 10240
}

class SampleUploader {
    private static var imageContext = CIContext(options: nil)

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

    @discardableResult func send(sampleBuffer: CMSampleBuffer, sampleBufferType: RPSampleBufferType) -> Bool {
        guard isReady else {
            return false
        }

        isReady = false

        dataToSend = prepare(sampleBuffer: sampleBuffer, sampleBufferType: sampleBufferType)
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

    func prepare(sampleBuffer: CMSampleBuffer, sampleBufferType: RPSampleBufferType) -> Data? {
        switch sampleBufferType {
        case .video:
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                logger.log(level: .debug, "image buffer not available")
                return nil
            }

            CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)

            let scaleFactor = 1.0
            let width = CVPixelBufferGetWidth(imageBuffer) / Int(scaleFactor)
            let height = CVPixelBufferGetHeight(imageBuffer) / Int(scaleFactor)

            let orientation = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil)?.uintValue ?? 0

            let scaleTransform = CGAffineTransform(scaleX: CGFloat(1.0 / scaleFactor), y: CGFloat(1.0 / scaleFactor))
            let bufferData = jpegData(from: imageBuffer, scale: scaleTransform)

            CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)

            guard let messageData = bufferData else {
                logger.log(level: .debug, "corrupted image buffer")
                return nil
            }

            let httpResponse = CFHTTPMessageCreateResponse(nil, 200, nil, kCFHTTPVersion1_1).takeRetainedValue()
            CFHTTPMessageSetHeaderFieldValue(httpResponse, "Content-Length" as CFString, String(messageData.count) as CFString)
            CFHTTPMessageSetHeaderFieldValue(httpResponse, "Buffer-Type" as CFString, "video" as CFString)
            CFHTTPMessageSetHeaderFieldValue(httpResponse, "Buffer-Width" as CFString, String(width) as CFString)
            CFHTTPMessageSetHeaderFieldValue(httpResponse, "Buffer-Height" as CFString, String(height) as CFString)
            CFHTTPMessageSetHeaderFieldValue(httpResponse, "Buffer-Orientation" as CFString, String(orientation) as CFString)
            CFHTTPMessageSetBody(httpResponse, messageData as CFData)

            return CFHTTPMessageCopySerializedMessage(httpResponse)?.takeRetainedValue() as Data?

        case .audioApp, .audioMic:
            let buffer = try? sampleBuffer.withAudioBufferList(flags: []) { abl, _ in
                let bytes = abl.unsafePointer.pointee.mBuffers.mData
                let byteSize = abl.unsafePointer.pointee.mBuffers.mDataByteSize
                let channels = abl.unsafePointer.pointee.mBuffers.mNumberChannels
                return (data: Data(bytes: bytes!, count: Int(byteSize)), channels: channels)
            }
            guard let buffer else { return nil }

            let httpResponse = CFHTTPMessageCreateResponse(nil, 200, nil, kCFHTTPVersion1_1).takeRetainedValue()
            CFHTTPMessageSetHeaderFieldValue(httpResponse, "Content-Length" as CFString, String(buffer.data.count) as CFString)
            CFHTTPMessageSetHeaderFieldValue(httpResponse, "Buffer-Type" as CFString, (sampleBufferType == .audioApp ? "audio-app" : "audio-mic") as CFString)
            CFHTTPMessageSetHeaderFieldValue(httpResponse, "Buffer-Channels" as CFString, String(buffer.channels) as CFString)
            CFHTTPMessageSetBody(httpResponse, buffer.data as CFData)

            return CFHTTPMessageCopySerializedMessage(httpResponse)?.takeRetainedValue() as Data?

        @unknown default: return nil
        }
    }

    func jpegData(from buffer: CVPixelBuffer, scale scaleTransform: CGAffineTransform) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer).transformed(by: scaleTransform)

        guard let colorSpace = image.colorSpace else {
            return nil
        }

        let options: [CIImageRepresentationOption: Float] = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0]

        return SampleUploader.imageContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }
}

#endif
