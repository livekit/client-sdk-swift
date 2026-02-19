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

@testable import LiveKit
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
            allowedTypeMismatches: ["canPublishSources"] // Array vs Set
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
        allowedTypeMismatches: Set<String> = []
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
                    sdk: sdkField.type
                ))
            }
        }

        for sdkField in sdkFields where protoFieldMap[sdkField.name] == nil {
            errors.append(.extraField(sdkField.name))
        }

        return errors
    }
}
