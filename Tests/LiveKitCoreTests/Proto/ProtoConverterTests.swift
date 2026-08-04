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
@testable import LiveKit
import LiveKitNanopb

private extension NanopbMessage {
    /// Dereferences the C storage so Mirror sees the proto fields.
    var _reflectedStorage: Any { _pointer.pointee }
}

import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

struct ProtoConverterTests {
    @Test func participantPermissions() {
        let errors = Comparator.compareStructures(
            proto: Livekit_ParticipantPermission(),
            sdk: ParticipantPermissions(),
            excludedFields: ["agent"], // deprecated
            allowedTypeMismatches: ["canPublishSources"], // Array vs Set
        )

        #expect(errors.isEmpty, Comment(rawValue: errors.description))
    }
}

enum Comparator {
    enum ComparisonError: Error, CustomStringConvertible {
        case missingField(String)
        case extraField(String)
        case typeMismatch(field: String, proto: String, sdk: String)

        var description: String {
            switch self {
            case let .missingField(field):
                "Missing field: '\(field)'"
            case let .extraField(field):
                "Extra field: '\(field)'"
            case let .typeMismatch(field, proto, sdk):
                "Type mismatch for '\(field)': proto has \(proto), sdk has \(sdk)"
            }
        }
    }

    struct FieldInfo {
        let name: String
        let type: String
        let nonOptionalType: String
    }

    static func extractFields(from instance: some Any, excludedFields: Set<String> = []) -> [FieldInfo] {
        // nanopb-backed facades keep proto fields in a C struct behind an
        // owner/pointer pair; reflect the pointed-to storage instead.
        if let message = instance as? any NanopbMessage {
            return extractNanopbFields(
                from: message._reflectedStorage, excludedFields: excludedFields,
            )
        }
        let mirror = Mirror(reflecting: instance)
        var fields: [FieldInfo] = []
        var backingFields: Set<String> = []

        // Collect all backing fields
        for child in mirror.children {
            guard let label = child.label, label.hasPrefix("_") else { continue }
            backingFields.insert(String(label.dropFirst())) // Remove the underscore
        }

        for child in mirror.children {
            guard let label = child.label else { continue }

            // Skip excluded/unknown fields
            if excludedFields.contains(label) || label == "unknownFields" {
                continue
            }

            // Skip private backing fields (they have public computed properties)
            if label.hasPrefix("_"), backingFields.contains(String(label.dropFirst())) {
                // But add the public version instead
                let publicName = String(label.dropFirst())
                let typeString = String(describing: type(of: child.value))
                let nonOptional = extractNonOptionalType(from: typeString)

                if !fields.contains(where: { $0.name == publicName }) {
                    fields.append(FieldInfo(name: publicName, type: typeString, nonOptionalType: nonOptional))
                }
                continue
            }

            // Skip other private fields
            if label.hasPrefix("_") {
                continue
            }

            let typeString = String(describing: type(of: child.value))
            let nonOptional = extractNonOptionalType(from: typeString)

            fields.append(FieldInfo(name: label, type: typeString, nonOptionalType: nonOptional))
        }

        return fields.sorted { $0.name < $1.name }
    }

    /// Fields of an imported nanopb C struct, normalised to proto camelCase
    /// names and Swift-ish types so they compare against SDK declarations.
    static func extractNanopbFields(from storage: Any, excludedFields: Set<String>) -> [FieldInfo] {
        var fields: [FieldInfo] = []
        for child in Mirror(reflecting: storage).children {
            guard let label = child.label else { continue }
            if label == "dummy_field" || label.hasPrefix("has_") || label.hasPrefix("which_")
                || label.hasSuffix("_count")
            {
                continue
            }
            let parts = label.split(separator: "_").map(String.init)
            let name = (parts.first ?? label) + parts.dropFirst()
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            if excludedFields.contains(name) { continue }

            // Optional<UnsafeMutablePointer<X>> -> X, then C spellings to Swift
            var type = extractNonOptionalType(from: String(describing: Swift.type(of: child.value)))
            if type.hasPrefix("UnsafeMutablePointer<"), type.hasSuffix(">") {
                type = String(type.dropFirst("UnsafeMutablePointer<".count).dropLast())
            }
            switch type {
            case "CChar", "Int8": type = "String"
            case "pb_bytes_array_t": type = "Data"
            default:
                if type.hasPrefix("livekit_") { type = String(type.dropFirst("livekit_".count)) }
            }
            fields.append(FieldInfo(name: name, type: type, nonOptionalType: type))
        }
        return fields.sorted { $0.name < $1.name }
    }

    static func extractNonOptionalType(from typeString: String) -> String {
        if typeString.hasPrefix("Optional<"), typeString.hasSuffix(">") {
            let start = typeString.index(typeString.startIndex, offsetBy: 9)
            let end = typeString.index(before: typeString.endIndex)
            return String(typeString[start ..< end])
        }
        return typeString
    }

    static func compareStructures(
        proto: some Any,
        sdk: some Any,
        excludedFields: Set<String> = [],
        allowedTypeMismatches: Set<String> = [],
    ) -> [ComparisonError] {
        let protoFields = extractFields(from: proto, excludedFields: excludedFields)
        let sdkFields = extractFields(from: sdk, excludedFields: excludedFields)

        var errors: [ComparisonError] = []

        let protoFieldMap = Dictionary(uniqueKeysWithValues: protoFields.map { ($0.name, $0) })
        let sdkFieldMap = Dictionary(uniqueKeysWithValues: sdkFields.map { ($0.name, $0) })

        for protoField in protoFields {
            guard let sdkField = sdkFieldMap[protoField.name] else {
                errors.append(.missingField(protoField.name))
                continue
            }

            if protoField.nonOptionalType != sdkField.nonOptionalType, !allowedTypeMismatches.contains(protoField.name) {
                errors.append(.typeMismatch(
                    field: protoField.name,
                    proto: protoField.type,
                    sdk: sdkField.type,
                ))
            }
        }

        for sdkField in sdkFields where protoFieldMap[sdkField.name] == nil {
            errors.append(.extraField(sdkField.name))
        }

        return errors
    }
}
