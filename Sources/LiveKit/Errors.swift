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

internal import LiveKitWebRTC

public enum LiveKitErrorType: Int, Sendable {
    case unknown = 0
    case cancelled = 100
    case timedOut = 101
    case failedToParseUrl = 102
    case failedToConvertData = 103
    case invalidState = 104
    case invalidParameter = 105

    case webRTC = 201

    case network // Network issue

    // Server
    case duplicateIdentity = 500
    case serverShutdown = 501
    case participantRemoved = 502
    case roomDeleted = 503
    case stateMismatch = 504
    case joinFailure = 505
    case insufficientPermissions = 506

    //
    case serverPingTimedOut = 601

    // Device related
    case deviceNotFound = 701
    case captureFormatNotFound = 702
    case unableToResolveFPSRange = 703
    case capturerDimensionsNotResolved = 704
    case deviceAccessDenied = 705

    // Audio
    case audioEngine = 801
    case audioSession = 802

    case codecNotSupported = 901
}

extension LiveKitErrorType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .cancelled:
            "Cancelled"
        case .timedOut:
            "Timed out"
        case .failedToParseUrl:
            "Failed to parse URL"
        case .failedToConvertData:
            "Failed to convert data"
        case .invalidState:
            "Invalid state"
        case .invalidParameter:
            "Invalid parameter"
        case .webRTC:
            "WebRTC error"
        case .network:
            "Network error"
        case .duplicateIdentity:
            "Duplicate Participant identity"
        case .serverShutdown:
            "Server shutdown"
        case .participantRemoved:
            "Participant removed"
        case .roomDeleted:
            "Room deleted"
        case .stateMismatch:
            "Server state mismatch"
        case .joinFailure:
            "Server join failure"
        case .serverPingTimedOut:
            "Server ping timed out"
        case .deviceNotFound:
            "Device not found"
        case .captureFormatNotFound:
            "Capture format not found"
        case .unableToResolveFPSRange:
            "Unable to resolve FPS range"
        case .capturerDimensionsNotResolved:
            "Capturer dimensions not resolved"
        case .audioEngine:
            "Audio Engine Error"
        case .audioSession:
            "Audio Session Error"
        default: "Unknown"
        }
    }
}

@objc
public class LiveKitError: NSError, @unchecked Sendable {
    public let type: LiveKitErrorType
    public let message: String?
    public let underlyingError: Error?

    override public var underlyingErrors: [Error] {
        [underlyingError].compactMap { $0 }
    }

    public init(_ type: LiveKitErrorType,
                message: String? = nil,
                internalError: Error? = nil)
    {
        func _computeDescription() -> String {
            if let message {
                return "\(String(describing: type))(\(message))"
            }
            return String(describing: type)
        }

        self.type = type
        self.message = message
        underlyingError = internalError
        super.init(domain: "io.livekit.swift-sdk",
                   code: type.rawValue,
                   userInfo: [NSLocalizedDescriptionKey: _computeDescription()])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension LiveKitError {
    static func from(error: Error?) -> LiveKitError? {
        guard let error else { return nil }
        if let error = error as? LiveKitError {
            return error
        }

        if error is CancellationError {
            return LiveKitError(.cancelled)
        }

        // TODO: Identify more network error types
        logger.log("Uncategorized error for: \(String(describing: error))", type: LiveKitError.self)
        return LiveKitError(.unknown)
    }

    static func from(reason: Livekit_DisconnectReason) -> LiveKitError {
        LiveKitError(reason.toLKType())
    }
}

extension Livekit_DisconnectReason {
    func toLKType() -> LiveKitErrorType {
        switch self {
        case .clientInitiated: .cancelled
        case .duplicateIdentity: .duplicateIdentity
        case .serverShutdown: .serverShutdown
        case .participantRemoved: .participantRemoved
        case .roomDeleted: .roomDeleted
        case .stateMismatch: .stateMismatch
        case .joinFailure: .joinFailure
        default: .unknown
        }
    }
}

// MARK: - LocalizedError

// Conform to LocalizedError for convenience with SwiftUI etc.
extension LiveKitError: LocalizedError {
    public var errorDescription: String? {
        // Simply return description for now
        description
    }
}
