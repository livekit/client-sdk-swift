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

/// How the server controls proactive FlexFEC protection for a subscribed video track.
///
/// - SeeAlso: ``FECProtection``
@objc
public enum FECProtectionMode: Int, Sendable {
    /// No repair packets. This is the default.
    case disabled
    /// Protection follows observed packet loss, like libwebrtc's own FEC. The level is ignored.
    case adaptive
    /// Constant protection at the given level, regardless of packet loss.
    case fixed
    /// Protection never drops below the given level; it rises under higher packet loss and
    /// returns to that floor once the loss subsides.
    case minimum
}

/// The share of packets the server spends on FlexFEC repairs in ``FECProtectionMode/fixed`` and
/// ``FECProtectionMode/minimum`` modes. Frames that span only a few packets get proportionally more.
///
/// - SeeAlso: ``FECProtection``
@objc
public enum FECProtectionLevel: Int, Sendable {
    /// Approximately 15% repair packet overhead.
    case low = 1
    /// Approximately 25% repair packet overhead.
    case medium = 2
    /// Approximately 35% repair packet overhead.
    case high = 3
}

/// Proactive FlexFEC protection the server adds to a subscribed video track.
///
/// The server sends repair packets alongside the track's media, so the receiver can recover lost
/// packets without waiting for a retransmission.
///
/// ```swift
/// try await publication.set(fecProtection: .adaptive)
/// try await publication.set(fecProtection: .minimum(.medium))
/// ```
///
/// - SeeAlso: ``RemoteTrackPublication/set(fecProtection:)``
@objcMembers
public final class FECProtection: NSObject, Sendable {
    /// How the protection is controlled.
    public let mode: FECProtectionMode

    /// The protection level, used by ``FECProtectionMode/fixed`` and ``FECProtectionMode/minimum``.
    public let level: FECProtectionLevel

    /// Creates a FlexFEC protection setting.
    ///
    /// - Parameters:
    ///   - mode: How the protection is controlled.
    ///   - level: The protection level, ignored unless `mode` is ``FECProtectionMode/fixed``
    ///     or ``FECProtectionMode/minimum``.
    public init(mode: FECProtectionMode, level: FECProtectionLevel = .low) {
        self.mode = mode
        self.level = level
    }

    /// No repair packets.
    public static let disabled = FECProtection(mode: .disabled)

    /// Protection that follows observed packet loss.
    public static let adaptive = FECProtection(mode: .adaptive)

    /// Constant protection at `level`, regardless of packet loss.
    public static func fixed(_ level: FECProtectionLevel) -> FECProtection {
        FECProtection(mode: .fixed, level: level)
    }

    /// Protection that never drops below `level` and rises under higher packet loss.
    public static func minimum(_ level: FECProtectionLevel) -> FECProtection {
        FECProtection(mode: .minimum, level: level)
    }

    var usesLevel: Bool {
        mode == .fixed || mode == .minimum
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return mode == other.mode && (!usesLevel || level == other.level)
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(mode)
        if usesLevel { hasher.combine(level) }
        return hasher.finalize()
    }

    override public var description: String {
        usesLevel ? "FECProtection(mode: \(mode), level: \(level))" : "FECProtection(mode: \(mode))"
    }
}

extension FECProtectionMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .disabled: "disabled"
        case .adaptive: "adaptive"
        case .fixed: "fixed"
        case .minimum: "minimum"
        }
    }
}

extension FECProtectionLevel: CustomStringConvertible {
    public var description: String {
        switch self {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
    }
}

extension FECProtection {
    func toPBType() -> Livekit_FECProtection {
        Livekit_FECProtection.with {
            $0.mode = mode.toPBType()
            if usesLevel {
                $0.level = level.toPBType()
            }
        }
    }
}

extension FECProtectionMode {
    func toPBType() -> Livekit_FECProtectionMode {
        switch self {
        case .disabled: .fecModeDisabled
        case .adaptive: .fecModeAdaptive
        case .fixed: .fecModeFixed
        case .minimum: .fecModeMinimum
        }
    }
}

extension FECProtectionLevel {
    func toPBType() -> Livekit_FECProtectionLevel {
        switch self {
        case .low: .fecLevelLow
        case .medium: .fecLevelMedium
        case .high: .fecLevelHigh
        }
    }
}
