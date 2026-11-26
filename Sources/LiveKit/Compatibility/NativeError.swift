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

internal import LiveKitFFI
import Foundation

extension LiveKitError {
    static func mappingNative(_ error: Error) -> Error {
        guard let native = error as? FfiRoomError else { return error }
        return from(native: native)
    }

    static func from(native: FfiRoomError) -> LiveKitError {
        switch native {
        case .Cancelled: LiveKitError(.cancelled, internalError: native)
        case .Closed, .TrackAlreadyPublished: LiveKitError(.invalidState, internalError: native)
        case let .InvalidState(reason): LiveKitError(.invalidState, message: reason, internalError: native)
        case let .Unsupported(reason): LiveKitError(.invalidParameter, message: reason, internalError: native)
        case let .Connection(reason): LiveKitError(.network, message: reason, internalError: native)
        case let .Rtc(_, reason): LiveKitError(.webRTC, message: reason, internalError: native)
        case let .RequestFailure(code, reason): LiveKitError(code == .notAllowed ? .insufficientPermissions : .invalidState, message: reason, internalError: native)
        case let .Signal(failure): from(signal: failure, original: native)
        case .Internal, .Overflow: LiveKitError(.unknown, internalError: native)
        @unknown default: LiveKitError(.unknown, internalError: native)
        }
    }

    // Exhaustive native signal variants; retain typed causes instead of parsing reasons.
    // swiftlint:disable:next cyclomatic_complexity
    private static func from(signal: NativeSignalFailure, original: FfiRoomError) -> LiveKitError {
        switch signal {
        case let .urlParse(reason): LiveKitError(.failedToParseUrl, message: reason, internalError: original)
        case .tokenFormat: LiveKitError(.validation, internalError: original)
        case let .http(source, status, reason):
            LiveKitError(httpType(source: source, status: status), message: reason, internalError: original, statusCode: Int(status))
        case let .timeout(reason): LiveKitError(.timedOut, message: reason, internalError: original)
        case let .region(reason): LiveKitError(.regionManager, message: reason, internalError: original)
        case .sendFailed, .transport: LiveKitError(.network, internalError: original)
        case .closed, .invalidState, .transportNotConfigured: LiveKitError(.invalidState, internalError: original)
        case let .leave(reason, _): LiveKitError(leaveType(reason))
        case .protoDecode: LiveKitError(.failedToConvertData, internalError: original)
        case .unknown: LiveKitError(.unknown, internalError: original)
        @unknown default: LiveKitError(.unknown, internalError: original)
        }
    }

    /// `livekit.DisconnectReason` wire values carried by a signal leave.
    private static func leaveType(_ reason: Int32) -> LiveKitErrorType {
        switch reason {
        case 1: .cancelled
        case 2: .duplicateIdentity
        case 3: .serverShutdown
        case 4: .participantRemoved
        case 5: .roomDeleted
        case 6: .stateMismatch
        case 7: .joinFailure
        default: .unknown
        }
    }

    private static func httpType(source: NativeHttpFailureSource, status: UInt16) -> LiveKitErrorType {
        if source == .webSocketHandshake || !(400 ..< 500).contains(status) || status == 429 { return .network }
        return status == 404 ? .serviceNotFound : .validation
    }
}
