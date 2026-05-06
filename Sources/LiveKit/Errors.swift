/*
 * Copyright 2026 LiveKit
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
    case validation // Validation issue
    // HTTP 404 from validation endpoint; distinct from .validation so the
    // v1 → v0 RTC path fallback can fire without masking token/permission errors.
    case serviceNotFound

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
    case soundPlayer = 803

    case codecNotSupported = 901

    // Encryption
    case encryptionFailed = 1001
    case decryptionFailed = 1002

    // LiveKit Cloud
    case onlyForCloud = 1101
    case regionManager = 1102

    // Data streams
    case dataStream = 1201
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
        case .validation:
            "Validation error"
        case .serviceNotFound:
            "Service not found"
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
        case .soundPlayer:
            "Sound Player Error"
        case .codecNotSupported:
            "Codec not supported"
        case .encryptionFailed:
            "Encryption failed"
        case .decryptionFailed:
            "Decryption failed"
        case .onlyForCloud:
            "Only for LiveKit Cloud"
        case .regionManager:
            "Region manager error"
        case .dataStream:
            "Data stream error"
        default: "Unknown"
        }
    }
}

@objcMembers
public class LiveKitError: NSError, @unchecked Sendable, Loggable {
    public let type: LiveKitErrorType
    public let message: String?
    public let internalError: Error?

    @available(*, deprecated, renamed: "internalError")
    public var underlyingError: Error? { internalError }

    override public var underlyingErrors: [Error] {
        [internalError].compactMap(\.self)
    }

    public init(_ type: LiveKitErrorType,
                message: String? = nil,
                internalError: Error? = nil)
    {
        func _computeDescription() -> String {
            var suffix = ""
            if let message {
                suffix = "(\(message))"
            } else if let internalError {
                suffix = "(\(internalError.localizedDescription))"
            }
            return String(describing: type) + suffix
        }

        self.type = type
        self.message = message
        self.internalError = internalError

        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: _computeDescription()]
        if let internalError {
            userInfo[NSUnderlyingErrorKey] = internalError as NSError
        }
        super.init(domain: "io.livekit.swift-sdk",
                   code: type.rawValue,
                   userInfo: userInfo)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

public extension LiveKitError {
    /// Wraps any `Error` as a `LiveKitError`. Pass-through for an existing
    /// `LiveKitError` (its type/message/internalError are forwarded);
    /// `CancellationError` becomes `.cancelled`; network errors become
    /// `.network`; `StreamError` becomes `.dataStream`; everything else
    /// becomes `.unknown` with `internalError` set.
    ///
    /// Designed for `throws(LiveKitError)` boundary catches:
    /// ```swift
    /// } catch {
    ///     throw LiveKitError(from: error)
    /// }
    /// ```
    convenience init(from error: any Error) {
        if let lk = error as? LiveKitError {
            self.init(lk.type, message: lk.message, internalError: lk.internalError)
            return
        }
        if error is CancellationError {
            self.init(.cancelled)
            return
        }
        if error.isNetworkError {
            self.init(.network, internalError: error)
            return
        }
        if error is StreamError {
            self.init(.dataStream, internalError: error)
            return
        }
        self.init(.unknown, internalError: error)
    }
}

extension LiveKitError {
    static func from(error: Error?) -> LiveKitError? {
        guard let error else { return nil }
        return LiveKitError(from: error)
    }

    static func from(reason: Livekit_DisconnectReason) -> LiveKitError {
        LiveKitError(reason.toLKType())
    }
}

/// Throws `LiveKitError(.cancelled)` if the current Task is cancelled.
///
/// Typed-throws counterpart to `Task.checkCancellation()` for use inside
/// `throws(LiveKitError)` contexts.
@inlinable
func checkCancellation() throws(LiveKitError) {
    if Task.isCancelled { throw LiveKitError(.cancelled) }
}

extension Error {
    /// Returns `true` for URLError, CFNetwork, and POSIX socket errors.
    var isNetworkError: Bool {
        if self is URLError { return true }
        let nsError = self as NSError
        switch nsError.domain {
        case NSURLErrorDomain,
             // CFNetwork errors (SSL/TLS failures, proxy issues, etc.)
             "kCFErrorDomainCFNetwork":
            return true
        case NSPOSIXErrorDomain:
            // Only whitelist known socket-related POSIX codes; non-network
            // errors (ENOMEM, EACCES, …) should not be classified as network errors.
            let socketCodes: Set<Int32> = [
                ECONNREFUSED, ECONNRESET, ECONNABORTED,
                ETIMEDOUT, ENETUNREACH, ENETDOWN,
                EHOSTUNREACH, EPIPE, ENOTCONN,
            ]
            return socketCodes.contains(Int32(nsError.code))
        default:
            return false
        }
    }

    /// Returns `true` for network/timeouts that should trigger region failover.
    var isRetryableForRegionFailover: Bool {
        if let liveKitError = self as? LiveKitError {
            switch liveKitError.type {
            case .network, .timedOut:
                return true
            default:
                return false
            }
        }

        return isNetworkError
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
