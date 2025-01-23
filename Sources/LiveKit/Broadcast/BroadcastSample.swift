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

#if canImport(ReplayKit)
import ReplayKit
#endif

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

/// A sample produced by the broadcast extension.
enum BroadcastSample {
    case image(CVImageBuffer, rotation: RTCVideoRotation)
    // TODO: add audio support
}

/// Decodes broadcast samples for consumption.
struct BroadcastSampleDecoder {
    
    enum Error: Swift.Error {
        case unsupportedSample
        case headerCorrupted
        case invalidBody
        case imageDecodingFailed
    }
    
    func decode(_ message: HTTPMessage) throws(Error) -> BroadcastSample {
        guard let typeRaw = message[.contentType]?.intValue,
              let type = ContentType(rawValue: typeRaw) else {
            throw .headerCorrupted
        }
        return switch type {
        case .image: try decode(image: message)
        case .audio:
            // TODO: add audio support
            throw .unsupportedSample
        }
    }
    
    private func decode(image message: HTTPMessage) throws(Error) -> BroadcastSample {
        guard let width = message[.bufferWidth]?.intValue,
              let height = message[.bufferHeight]?.intValue,
              let orientationRaw = message[.bufferOrientation]?.uint32Value,
              let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) else {
            throw .headerCorrupted
        }
        guard let body = message.body else {
            throw .invalidBody
        }
        guard let imageBuffer = BroadcastImageCodec.imageBuffer(from: body, width: width, height: height) else {
            throw .imageDecodingFailed
        }
        return .image(imageBuffer, rotation: RTCVideoRotation(orientation))
    }
    
    // TODO: add audio support
}

/// Encodes broadcast samples for transport.
struct BroadcastSampleEncoder {
    enum Error: Swift.Error {
        case invalidSample
        case unsupportedSample
        case imageEncodingFailed
        case missingImageBuffer
        case serializationFailed
    }

    /// Configures desired compression quality (0.0 = max compression, 1.0 = least compression).
    let compressionQuality: CGFloat = 1.0

    func encode(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) throws(Error) -> Data {
        guard sampleBuffer.isValid else {
            throw .invalidSample
        }
        switch type {
        case .video:
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                throw .missingImageBuffer
            }
            return try encode(imageBuffer)
        default:
            // TODO: add audio support
            throw .unsupportedSample
        }
    }

    private func encode(_ imageBuffer: CVImageBuffer) throws(Error) -> Data {
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        let orientation = CMGetAttachment(
            imageBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        )?.uintValue ?? 0

        guard let jpegData = BroadcastImageCodec.jpegData(from: imageBuffer, quality: compressionQuality) else {
            throw .imageEncodingFailed
        }
        CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)

        var message = HTTPMessage()
        message[.contentType] = String(ContentType.image.rawValue)
        message[.bufferWidth] = String(width)
        message[.bufferHeight] = String(height)
        message[.bufferOrientation] = String(orientation)
        message.body = jpegData

        guard let serializedMessage = Data(message) else {
            throw .serializationFailed
        }
        return serializedMessage
    }

    // TODO: add audio support
}

// MARK: Message Constants

fileprivate enum ContentType: Int {
    case image, audio
}

fileprivate extension HTTPMessage.HeaderKey {
    static let bufferWidth = Self(rawValue: "Buffer-Width")
    static let bufferHeight = Self(rawValue: "Buffer-Height")
    static let bufferOrientation = Self(rawValue: "Buffer-Orientation")
}

// MARK: - Supporting Extensions

fileprivate extension RTCVideoRotation {
    init(_ orientation: CGImagePropertyOrientation) {
        self = switch orientation {
        case .left: ._90
        case .down: ._180
        case .right: ._270
        default: ._0
        }
    }
}

fileprivate extension String {
    var intValue: Int? { Int(self) }
    var uint32Value: UInt32? { UInt32(self) }
}

#endif
