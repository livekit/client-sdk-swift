#!/usr/bin/env swift-sh

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

// swift-sh scripts are single-file by design.
// swiftlint:disable file_length

import ArgumentParser // apple/swift-argument-parser ~> 1.3
import Files // JohnSundell/Files ~> 4.2
import Foundation
import SwiftProtobuf
import SwiftProtobufPluginLibrary // apple/swift-protobuf ~> 1.38

// Run via: swiftly run +xcode swift-sh scripts/generate-swift-protos.swift
//
// Emits Swift facades over nanopb's generated C structs.
//
// Input is the `FileDescriptorSet` protoc emits (--descriptor_set_out), parsed
// with SwiftProtobufPluginLibrary — the same structured descriptor model and
// `SwiftProtobufNamer` that protoc-gen-swift itself is built on. Nothing here
// parses C headers or scrapes generated Swift for names.
//
// The C layout is *predicted* from nanopb's deterministic naming rules under
// blanket `FT_POINTER` (see Makefile): every field is a pointer member named
// after the proto field, oneofs become `which_<name>` + a union, repeated
// fields get `<name>_count`, and tags are `<cmsg>_<field>_tag`. A wrong
// prediction cannot ship: the emitted Swift compiles against the real headers,
// so any mismatch is a build error, never silent layout corruption.
//
// Messages are immutable value types with zero-copy views for submessage and
// repeated access; each carries a noncopyable `Builder` that owns fresh storage
// and is the only way to mutate (see Sources/LiveKitNanopb).

struct GenerateSwiftProtos: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate immutable Swift facades over nanopb C structs.",
    )

    @Option(help: "FileDescriptorSet produced by protoc --include_imports --descriptor_set_out.")
    var descriptors = ".build/proto-stage/descriptors.pb"

    @Option(help: "Directory holding nanopb's generated headers (callback tripwire only).")
    var headers = "Sources/CLiveKitProto/include"

    @Option(help: "Where to write the generated facades.")
    var output = "Sources/LiveKit/Protos"

    @Option(help: "Where to write the generated conformance exemplars (test target).")
    var testOutput = "Tests/LiveKitNanopbTests/Generated"

    @Flag(inversion: .prefixedNo, help: "Emit facades only for types reachable from SDK code.")
    var prune = true

    /// Proto files that get facades. Imports pulled in by --include_imports
    /// (logger/options.proto, descriptor.proto) carry no client messages.
    static let facadeFiles: Set<String> = [
        "livekit_models.proto", "livekit_rtc.proto", "livekit_metrics.proto",
        "google/protobuf/timestamp.proto",
    ]

    func run() throws {
        // A pb_callback_t field means a proto field slipped past the blanket
        // FT_POINTER options — nanopb would silently drop it on decode.
        try Self.verifyNoCallbacks(headers: headers)

        let data = try Data(contentsOf: URL(filePath: descriptors))
        let set = try DescriptorSet(proto: Google_Protobuf_FileDescriptorSet(serializedBytes: data))
        let namer = SwiftProtobufNamer()

        let files = set.files.filter { Self.facadeFiles.contains($0.name) }
        guard !files.isEmpty else {
            throw ValidationError("no facade protos found in \(descriptors)")
        }

        let keep = prune ? Reachability(files: files, namer: namer)
            .closure(from: Self.usedTypeNames()) : nil

        let outFolder = try Folder(path: output)
        var stats = Stats()
        for file in files {
            let emitter = Emitter(namer: namer)
            var body = Self.fileHeader
            for message in file.messages where keep?.contains(message.fullName) != false {
                body += emitter.emit(message, depth: 0)
                stats.add(message)
            }
            for enumType in file.enums where keep?.contains(enumType.fullName) != false {
                body += emitter.emit(enum: enumType, depth: 0)
                stats.enums += 1
            }
            let stem = String(file.name.split(separator: "/").last!.dropLast(".proto".count))
            let out = try outFolder.createFile(named: "\(stem)+Nanopb.swift")
            try out.write(body)
        }

        try Self.verifyBuilderInvariant(in: outFolder)

        let exemplars = ExemplarEmitter(namer: namer).emit(files: files, keep: keep)
        let testFolder = try Folder(path: ".").createSubfolderIfNeeded(at: testOutput)
        try testFolder.createFile(named: "ConformanceExemplars.swift").write(exemplars.source)

        let emitted = stats.messages + stats.enums
        print("""
        messages : \(stats.messages)  (nested: \(stats.nested))
        enums    : \(stats.enums)
        fields   : \(stats.fields)
        oneofs   : \(stats.oneofs)
        emitted  : \(emitted) types (prune \(prune ? "on" : "off"))
        exemplars: \(exemplars.messages) messages, \(exemplars.oneofVariants) oneof variants
        output   : \(output)
        """)
    }

    /// Type names spelled anywhere in hand-written SDK or test code.
    static func usedTypeNames() -> Set<String> {
        var used: Set<String> = []
        let typeName = #/\b(?:Livekit|Google_Protobuf)_[A-Za-z0-9_]+/#
        for root in ["Sources/LiveKit", "Tests"] {
            guard let folder = try? Folder(path: root) else { continue }
            for file in folder.files.recursive where file.name.hasSuffix(".swift") {
                let path = file.path
                if path.contains("/Protos/") || path.contains("/Oracle/")
                    || path.contains("/Generated/") { continue }
                guard let text = try? file.readAsString() else { continue }
                for match in text.matches(of: typeName) {
                    used.insert(String(match.output))
                }
            }
        }
        return used
    }

    static func verifyNoCallbacks(headers: String) throws {
        var violations: [String] = []
        let callbackField = #/pb_callback_t (\w+);/#
        for file in try Folder(path: headers).files.recursive where file.name.hasSuffix(".pb.h") {
            let text = try file.readAsString()
            for match in text.matches(of: callbackField) {
                violations.append("\(file.name): \(match.1)")
            }
        }
        guard violations.isEmpty else {
            throw ValidationError("""
            nanopb emitted callback fields (data would be silently dropped):
            \(violations.joined(separator: "\n"))
            Check the blanket FT_POINTER options in the Makefile and re-run make proto.
            """)
        }
    }

    /// Messages are immutable; every setter must live on a `Builder`, which
    /// owns storage nothing else can reach. A setter that escaped onto a
    /// message would let one value mutate storage its copies and views share.
    static func verifyBuilderInvariant(in folder: Folder) throws {
        var violations: [String] = []
        for file in folder.files where file.name.hasSuffix("+Nanopb.swift") {
            var insideBuilder = false
            var builderDepth = 0
            var depth = 0
            for (index, line) in try file.readAsString()
                .components(separatedBy: "\n").enumerated()
            {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("struct Builder: ~Copyable") {
                    insideBuilder = true
                    builderDepth = depth
                }
                depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                if insideBuilder, depth <= builderDepth { insideBuilder = false }

                if trimmed.contains("_ensureUnique") {
                    violations.append("\(file.name):\(index + 1): leftover copy-on-write guard")
                }
                guard trimmed.hasPrefix("set {") || trimmed.hasPrefix("nonmutating set {")
                else { continue }
                if !insideBuilder {
                    violations.append("\(file.name):\(index + 1): setter outside a Builder")
                } else if !trimmed.hasPrefix("nonmutating set") {
                    violations.append("\(file.name):\(index + 1): builder setter must be nonmutating")
                }
            }
        }
        guard violations.isEmpty else {
            throw ValidationError("""
            Generated accessors violate the immutable-message invariant:
            \(violations.joined(separator: "\n"))
            """)
        }
    }

    static let fileHeader = """
    // Generated by scripts/generate-swift-protos.swift — do not edit.
    //
    // Immutable value facades over nanopb's C structs; mutation goes through
    // each message's noncopyable Builder. See Sources/LiveKitNanopb.

    import Foundation

    // Single-module builds compile these sources into the product directly:
    // CocoaPods surfaces the C declarations through the umbrella header, while
    // the prebuilt xcframework resolves CLiveKitProto via its modulemap — the
    // internal import keeps it out of the emitted .swiftinterface.
    #if LK_XCFRAMEWORK
    internal import CLiveKitProto
    #elseif !COCOAPODS
    import CLiveKitProto
    import LiveKitNanopb
    #endif


    """
}

// MARK: - Stats

struct Stats {
    var messages = 0, nested = 0, enums = 0, fields = 0, oneofs = 0

    mutating func add(_ message: Descriptor, isNested: Bool = false) {
        messages += 1
        if isNested { nested += 1 }
        fields += message.fields.count
        oneofs += Emitter.realOneofs(of: message).count
        enums += message.enums.count
        for child in message.messages {
            add(child, isNested: true)
        }
    }
}

// MARK: - Reachability

/// Which top-level messages/enums the SDK can reach. Facades are pure API —
/// the C tables always carry the full wire format — so pruning cannot affect
/// round-tripping of unused fields.
struct Reachability {
    let files: [FileDescriptor]
    let namer: SwiftProtobufNamer

    /// The namer module-qualifies well-known types (SwiftProtobuf.Google_Protobuf_*);
    /// our facades for them live in this module.
    static func local(_ name: String) -> String {
        name.hasPrefix("SwiftProtobuf.") ? String(name.dropFirst("SwiftProtobuf.".count)) : name
    }

    /// Returns kept *proto* full names (e.g. "livekit.Room"), top-level only.
    func closure(from usedSwiftNames: Set<String>) -> Set<String> {
        var topLevel: [String: Descriptor] = [:] // proto fullName -> descriptor
        var bySwift: [String: String] = [:] // Swift name -> proto fullName
        var topLevelEnums: Set<String> = []

        for file in files {
            for message in file.messages {
                topLevel[message.fullName] = message
                bySwift[Self.local(namer.fullName(message: message))] = message.fullName
            }
            for enumType in file.enums {
                topLevelEnums.insert(enumType.fullName)
                bySwift[Self.local(namer.fullName(enum: enumType))] = enumType.fullName
            }
        }

        var kept = Set(usedSwiftNames.compactMap { bySwift[$0] }.filter { topLevel[$0] != nil })
        var keptEnums = Set(usedSwiftNames.compactMap { bySwift[$0] }
            .filter { topLevelEnums.contains($0) })
        var queue = Array(kept)

        func topAncestor(_ message: Descriptor) -> Descriptor {
            var ancestor = message
            while let parent = ancestor.containingType {
                ancestor = parent
            }
            return ancestor
        }

        func visit(_ message: Descriptor) {
            for field in message.fields {
                if field.type == .message || field.type == .group, let target = field.messageType {
                    let ancestor = topAncestor(target).fullName
                    if topLevel[ancestor] != nil, kept.insert(ancestor).inserted {
                        queue.append(ancestor)
                    }
                } else if field.type == .enum, let enumType = field.enumType,
                          topLevelEnums.contains(enumType.fullName)
                {
                    keptEnums.insert(enumType.fullName)
                }
            }
            for child in message.messages {
                visit(child)
            }
        }
        while let name = queue.popLast() {
            if let message = topLevel[name] { visit(message) }
        }
        return kept.union(keptEnums)
    }
}

// MARK: - Emission

/// Splits the accessors emitted for a field into the read-only half that
/// stays on the message and the mutating half that moves to its `Builder`.
enum AccessorSplitter {
    /// Accessors emitted for one field, split by where they belong: the
    /// message keeps reads, the builder takes every mutation.
    struct SplitAccessors {
        var message: [String] = []
        var builder: [String] = []

        mutating func append(_ other: SplitAccessors) {
            if !other.message.isEmpty { message += other.message + [""] }
            if !other.builder.isEmpty { builder += other.builder + [""] }
        }
    }

    static func braceDelta(_ line: String) -> Int {
        line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
    }

    static func isSetterLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "set {" || trimmed.hasPrefix("set { ")
    }

    /// `var x: T { get { ... } set { ... } }` -> `var x: T { ... }`
    static func getterOnly(_ member: [String]) -> [String] {
        guard let start = member.firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed == "get {" || trimmed.hasPrefix("get { ")
        }) else { return member }

        let first = member[start]
        if braceDelta(first) == 0 { // single-expression getter
            var inner = first.trimmingCharacters(in: .whitespaces)
            inner = String(inner.dropFirst("get {".count))
            if inner.hasSuffix("}") { inner = String(inner.dropLast()) }
            return [member[0], "    " + inner.trimmingCharacters(in: .whitespaces), "}"]
        }

        var body: [String] = []
        var depth = braceDelta(first)
        var index = start + 1
        while index < member.count, depth > 0 {
            depth += braceDelta(member[index])
            if depth == 0 { break }
            let line = member[index]
            body.append(line.hasPrefix("    ") ? String(line.dropFirst(4)) : line)
            index += 1
        }
        return [member[0]] + body + ["}"]
    }

    static func asBuilderMember(_ member: [String]) -> [String] {
        member.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "_ensureUnique()" { return nil }
            return line
                .replacingOccurrences(of: "_ensureUnique(); ", with: "")
                .replacingOccurrences(of: "mutating func", with: "func")
                .replacingOccurrences(of: "set {", with: "nonmutating set {")
        }
    }

    /// Route each emitted member to the message, the builder, or both.
    static func split(_ lines: [String]) -> SplitAccessors {
        var result = SplitAccessors()
        var index = 0
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }
            var member: [String] = []
            var depth = 0
            repeat {
                depth += braceDelta(lines[index])
                member.append(lines[index])
                index += 1
            } while index < lines.count && depth > 0

            let head = member[0].trimmingCharacters(in: .whitespaces)
            if head.contains("mutating func") {
                result.builder += asBuilderMember(member)
            } else if member.contains(where: isSetterLine) {
                result.message += getterOnly(member)
                result.builder += asBuilderMember(member)
            } else {
                result.message += member
            }
        }
        return result
    }
}

struct Emitter {
    let namer: SwiftProtobufNamer

    /// The namer module-qualifies well-known types (SwiftProtobuf.Google_Protobuf_*);
    /// our facades for them live in this module.
    static func local(_ name: String) -> String {
        name.hasPrefix("SwiftProtobuf.") ? String(name.dropFirst("SwiftProtobuf.".count)) : name
    }

    /// Oneofs excluding the synthetic ones protoc creates for proto3 `optional`.
    static func realOneofs(of message: Descriptor) -> [OneofDescriptor] {
        var seen: Set<String> = []
        var out: [OneofDescriptor] = []
        for field in message.fields {
            guard let oneof = field.realContainingOneof else { continue }
            if seen.insert(oneof.name).inserted { out.append(oneof) }
        }
        return out
    }

    /// nanopb's C type name: proto full name with dots as underscores.
    private func cName(_ message: Descriptor) -> String {
        message.fullName.replacingOccurrences(of: ".", with: "_")
    }

    private func scalar(
        _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
    ) -> (swift: String, zero: String)? {
        switch type {
        case .double: ("Double", "0")
        case .float: ("Float", "0")
        case .int64, .sint64, .sfixed64: ("Int64", "0")
        case .uint64, .fixed64: ("UInt64", "0")
        case .int32, .sint32, .sfixed32: ("Int32", "0")
        case .uint32, .fixed32: ("UInt32", "0")
        case .bool: ("Bool", "false")
        default: nil
        }
    }

    // MARK: fields

    private func emit(_ field: FieldDescriptor, of _: Descriptor) -> [String] {
        if field.isMap { return emitMap(field) }
        if field.isRepeated { return emitRepeated(field) }

        let names = namer.messagePropertyNames(field: field, prefixed: "", includeHasAndClear: true)
        let slot = "_pointer.pointee.\(Self.escaped(field.name))"

        switch field.type {
        case .string:
            return emitString(names, slot)
        case .bytes:
            return emitBytes(names, slot)
        case .enum:
            let type = Self.local(namer.fullName(enum: field.enumType!))
            return [
                "var \(names.name): \(type) {",
                "    get { \(slot).map { lkEnum($0.pointee) } ?? \(type)() }",
                "    set { _ensureUnique(); lkSetEnumPointer(&\(slot), newValue) }",
                "}",
                "var \(names.has): Bool { \(slot) != nil }",
            ]
        case .message, .group:
            let type = Self.local(namer.fullName(message: field.messageType!))
            return [
                "var \(names.name): \(type) {",
                "    get { \(slot).map { \(type)(_sharing: $0, owner: _owner) } ?? \(type)() }",
                "    set { _ensureUnique(); lkSetMessage(&\(slot), newValue) }",
                "}",
                "var \(names.has): Bool { \(slot) != nil }",
            ]
        default:
            let scalarType = scalar(field.type)!
            return [
                "var \(names.name): \(scalarType.swift) {",
                "    get { \(slot)?.pointee ?? \(scalarType.zero) }",
                "    set { _ensureUnique(); lkSetValue(&\(slot), newValue) }",
                "}",
                "var \(names.has): Bool { \(slot) != nil }",
            ]
        }
    }

    private func emitString(_ names: SwiftProtobufNamer.MessageFieldNames, _ slot: String) -> [String] {
        let capitalised = names.has.dropFirst("has".count)
        return [
            "var \(names.name): String {",
            "    get { lkString(\(slot)) ?? \"\" }",
            "    set { _ensureUnique(); lkSetString(&\(slot), newValue) }",
            "}",
            "var \(names.has): Bool { \(slot) != nil }",
            "/// Zero-copy read — borrows nanopb's allocation for the call only.",
            "func with\(capitalised)Bytes<R>(_ body: (UnsafeRawBufferPointer?) throws -> R) rethrows -> R {",
            "    try withLkBytes(\(slot), body)",
            "}",
        ]
    }

    private func emitBytes(_ names: SwiftProtobufNamer.MessageFieldNames, _ slot: String) -> [String] {
        let capitalised = names.has.dropFirst("has".count)
        return [
            "var \(names.name): Data {",
            "    get { lkData(\(slot)) }",
            "    set { _ensureUnique(); lkSetData(&\(slot), newValue) }",
            "}",
            "var \(names.has): Bool { \(slot) != nil }",
            "func with\(capitalised)<R>(_ body: (UnsafeRawBufferPointer?) throws -> R) rethrows -> R {",
            "    try withLkData(\(slot), body)",
            "}",
        ]
    }

    private func emitRepeated(_ field: FieldDescriptor) -> [String] {
        let names = namer.messagePropertyNames(field: field, prefixed: "", includeHasAndClear: false)
        let count = "_pointer.pointee.\(field.name)_count"
        let base = "_pointer.pointee.\(Self.escaped(field.name))"

        func accessor(_ type: String, get: String, set: String) -> [String] {
            [
                "var \(names.name): [\(type)] {",
                "    get { \(get) }",
                "    set {",
                "        _ensureUnique()",
                "        var count = \(count), base = \(base)",
                "        \(set)(&count, &base, newValue)",
                "        \(count) = count; \(base) = base",
                "    }",
                "}",
            ]
        }

        switch field.type {
        case .string:
            return accessor("String", get: "lkRepeated(\(count), \(base))", set: "lkSetRepeated")
        case .enum:
            return accessor(
                Self.local(namer.fullName(enum: field.enumType!)),
                get: "lkRepeatedEnum(\(count), \(base))", set: "lkSetRepeatedEnum",
            )
        case .message, .group:
            return accessor(
                Self.local(namer.fullName(message: field.messageType!)),
                get: "lkViews(\(count), \(base), owner: _owner)", set: "lkSetRepeatedMessages",
            )
        default:
            return accessor(
                scalar(field.type)!.swift,
                get: "lkRepeated(\(count), \(base))", set: "lkSetRepeated",
            )
        }
    }

    private func emitMap(_ field: FieldDescriptor) -> [String] {
        let names = namer.messagePropertyNames(field: field, prefixed: "", includeHasAndClear: false)
        let entry = field.messageType!
        let entryType = Self.local(namer.fullName(message: entry))
        let count = "_pointer.pointee.\(field.name)_count"
        let base = "_pointer.pointee.\(Self.escaped(field.name))"
        let key = entry.fields.first { $0.name == "key" }!
        let value = entry.fields.first { $0.name == "value" }!
        let keyType = key.type == .string ? "String" : scalar(key.type)!.swift
        let valueType: String = switch value.type {
        case .string: "String"
        case .bytes: "Data"
        case .enum: Self.local(namer.fullName(enum: value.enumType!))
        case .message: Self.local(namer.fullName(message: value.messageType!))
        default: scalar(value.type)!.swift
        }
        return [
            "var \(names.name): [\(keyType): \(valueType)] {",
            "    get {",
            "        var out: [\(keyType): \(valueType)] = [:]",
            "        for entry in lkViews(\(count), \(base), owner: _owner) as [\(entryType)] {",
            "            out[entry.key] = entry.value",
            "        }",
            "        return out",
            "    }",
            "    set {",
            "        _ensureUnique()",
            "        // sorted for deterministic encoding (bytes-based Equatable)",
            "        let entries = newValue.sorted { $0.key < $1.key }.map { pair in",
            "            \(entryType).with { $0.key = pair.key; $0.value = pair.value }",
            "        }",
            "        var count = \(count), base = \(base)",
            "        lkSetRepeatedMessages(&count, &base, entries)",
            "        \(count) = count; \(base) = base",
            "    }",
            "}",
        ]
    }

    /// A proto field may be named after a Swift keyword (e.g. `protocol`) —
    /// the imported C member needs backticks on the Swift side.
    static func escaped(_ identifier: String) -> String {
        keywords.contains(identifier) ? "`\(identifier)`" : identifier
    }

    private static let keywords: Set<String> = [
        "protocol", "class", "struct", "enum", "func", "var", "let", "return", "default",
        "internal", "public", "private", "static", "operator", "extension", "import",
        "where", "repeat", "in", "is", "as", "self", "super", "true", "false", "nil",
    ]
}

// MARK: - Oneofs — protoc-gen-swift's `OneOf_X` enum-with-payload shape

extension Emitter {
    /// Everything oneof emission derives from the descriptor pair.
    private struct OneofContext {
        let oneof: OneofDescriptor
        let enumName: String
        let property: String
        let clearName: String
        let which: String
        let tag: (FieldDescriptor) -> String
        let caseName: (FieldDescriptor) -> String
        var variants: [FieldDescriptor] { oneof.fields.sorted { $0.number < $1.number } }
    }

    private func context(oneof: OneofDescriptor, of message: Descriptor) -> OneofContext {
        let enumName = namer.relativeName(oneof: oneof)
        let storage = cName(message)
        let namer = namer
        return OneofContext(
            oneof: oneof,
            enumName: enumName,
            property: namer.messagePropertyName(oneof: oneof, prefixed: "").name,
            clearName: "_clear\(enumName.dropFirst("OneOf_".count))",
            which: "_pointer.pointee.which_\(oneof.name)",
            tag: { "pb_size_t(\(storage)_\($0.name)_tag)" },
            caseName: {
                namer.messagePropertyNames(field: $0, prefixed: "", includeHasAndClear: false).name
            },
        )
    }

    func emit(oneof: OneofDescriptor, of message: Descriptor) -> [String] {
        let ctx = context(oneof: oneof, of: message)
        var out = ["enum \(ctx.enumName): Equatable {"]
        for variant in ctx.variants {
            out.append("    case \(ctx.caseName(variant))(\(payloadType(variant)))")
        }
        out.append("}")
        out.append("")
        out += emitProperty(ctx)
        out.append("")
        out += emitVariantAccessors(ctx)
        out.append("")
        out += emitClear(ctx)
        return out
    }

    private func emitProperty(_ ctx: OneofContext) -> [String] {
        var out = ["var \(ctx.property): \(ctx.enumName)? {"]
        out.append("    get {")
        out.append("        switch \(ctx.which) {")
        for variant in ctx.variants {
            out.append("        case \(ctx.tag(variant)):")
            out.append("            return .\(ctx.caseName(variant))(\(read(variant, in: ctx.oneof)))")
        }
        out.append("        default: return nil")
        out.append("        }")
        out.append("    }")
        out.append("    set {")
        out.append("        _ensureUnique()")
        out.append("        \(ctx.clearName)()")
        out.append("        switch newValue {")
        for variant in ctx.variants {
            out.append("        case let .\(ctx.caseName(variant))(value):")
            out.append("            \(ctx.which) = \(ctx.tag(variant))")
            out.append("            \(write(variant, in: ctx.oneof, from: "value"))")
        }
        out.append("        case nil: break")
        out.append("        }")
        out.append("    }")
        out.append("}")
        return out
    }

    /// Direct per-variant accessors, as protoc-gen-swift emits.
    private func emitVariantAccessors(_ ctx: OneofContext) -> [String] {
        var out: [String] = []
        for variant in ctx.variants {
            out.append("var \(ctx.caseName(variant)): \(payloadType(variant)) {")
            out.append("    get { \(ctx.which) == \(ctx.tag(variant)) ? (\(read(variant, in: ctx.oneof))) : \(defaultValue(variant)) }")
            out.append("    set {")
            out.append("        _ensureUnique()")
            out.append("        \(ctx.clearName)()")
            out.append("        \(ctx.which) = \(ctx.tag(variant))")
            out.append("        \(write(variant, in: ctx.oneof, from: "newValue"))")
            out.append("    }")
            out.append("}")
        }
        return out
    }

    /// Releases the live variant with the right layout before switching.
    private func emitClear(_ ctx: OneofContext) -> [String] {
        var out = ["private mutating func \(ctx.clearName)() {"]
        out.append("    switch \(ctx.which) {")
        for variant in ctx.variants {
            let slot = "_pointer.pointee.\(ctx.oneof.name).\(Self.escaped(variant.name))"
            out.append("    case \(ctx.tag(variant)):")
            switch variant.type {
            case .message, .group:
                let type = Self.local(namer.fullName(message: variant.messageType!))
                out.append("        lkRelease(message: &\(slot), \(type).descriptor)")
            default:
                out.append("        lkFree(&\(slot))")
            }
        }
        out.append("    default: break")
        out.append("    }")
        out.append("    \(ctx.which) = 0")
        out.append("    // zero the union: stale bits from a previous variant would otherwise")
        out.append("    // be misread as a pointer by the next variant's setter")
        out.append("    _pointer.pointee.\(ctx.oneof.name) = .init()")
        out.append("}")
        return out
    }

    private func read(_ variant: FieldDescriptor, in oneof: OneofDescriptor) -> String {
        let slot = "_pointer.pointee.\(oneof.name).\(Self.escaped(variant.name))"
        switch variant.type {
        case .string: return "lkString(\(slot)) ?? \"\""
        case .bytes: return "lkData(\(slot))"
        case .enum:
            let type = Self.local(namer.fullName(enum: variant.enumType!))
            return "\(slot).map { lkEnum($0.pointee) as \(type) } ?? \(type)()"
        case .message, .group:
            let type = Self.local(namer.fullName(message: variant.messageType!))
            return "\(slot).map { \(type)(_sharing: $0, owner: _owner) } ?? \(type)()"
        default:
            return "\(slot)?.pointee ?? \(scalar(variant.type)!.zero)"
        }
    }

    private func write(
        _ variant: FieldDescriptor, in oneof: OneofDescriptor, from source: String,
    ) -> String {
        let slot = "_pointer.pointee.\(oneof.name).\(Self.escaped(variant.name))"
        switch variant.type {
        case .string: return "lkSetString(&\(slot), \(source))"
        case .bytes: return "lkSetData(&\(slot), \(source))"
        case .enum: return "lkSetEnumPointer(&\(slot), \(source))"
        case .message, .group: return "lkSetMessage(&\(slot), \(source))"
        default: return "lkSetValue(&\(slot), \(source))"
        }
    }

    private func payloadType(_ variant: FieldDescriptor) -> String {
        switch variant.type {
        case .string: "String"
        case .bytes: "Data"
        case .enum: Self.local(namer.fullName(enum: variant.enumType!))
        case .message, .group: Self.local(namer.fullName(message: variant.messageType!))
        default: scalar(variant.type)!.swift
        }
    }

    private func defaultValue(_ variant: FieldDescriptor) -> String {
        switch variant.type {
        case .string: "\"\""
        case .bytes: "Data()"
        case .enum: "\(Self.local(namer.fullName(enum: variant.enumType!)))()"
        case .message, .group: "\(Self.local(namer.fullName(message: variant.messageType!)))()"
        default: scalar(variant.type)!.zero
        }
    }
}

// MARK: - Enums

extension Emitter {
    func emit(enum enumType: EnumDescriptor, depth: Int) -> String {
        let pad = String(repeating: "    ", count: depth)
        let type = namer.relativeName(enum: enumType)
        let values = namer.uniquelyNamedValues(enum: enumType)
        let names = values.map { namer.relativeName(enumValue: $0) }
        let first = names.first ?? "unknown"

        var out = "\(pad)enum \(type): NanopbEnum, CaseIterable {\n"
        for name in names {
            out += "\(pad)    case \(name)\n"
        }
        out += "\(pad)    case UNRECOGNIZED(Int)\n\n"
        out += "\(pad)    init() { self = .\(first) }\n\n"
        out += "\(pad)    init?(rawValue: Int) {\n\(pad)        switch rawValue {\n"
        for (value, name) in zip(values, names) {
            out += "\(pad)        case \(value.number): self = .\(name)\n"
        }
        out += "\(pad)        default: self = .UNRECOGNIZED(rawValue)\n"
        out += "\(pad)        }\n\(pad)    }\n\n"
        out += "\(pad)    var rawValue: Int {\n\(pad)        switch self {\n"
        for (value, name) in zip(values, names) {
            out += "\(pad)        case .\(name): \(value.number)\n"
        }
        out += "\(pad)        case let .UNRECOGNIZED(value): value\n"
        out += "\(pad)        }\n\(pad)    }\n\n"
        out += "\(pad)    static var allCases: [\(type)] {\n\(pad)        ["
        out += names.map { ".\($0)" }.joined(separator: ", ")
        out += "]\n\(pad)    }\n"
        out += "\(pad)}\n\n"
        return out
    }
}

// MARK: - Conformance exemplars

/// Emits a deterministic, fully-populated exemplar of every facade message,
/// built through BOTH implementations from the same descriptor walk, plus one
/// exemplar per oneof variant. ExemplarConformanceTests asserts the two
/// encodings are byte-identical and that facade decode→encode is stable —
/// coverage of every field is mechanical, so it can't rot as protos change.
extension Emitter {
    func emit(_ message: Descriptor, depth: Int) -> String {
        let pad = String(repeating: "    ", count: depth)
        let type = namer.relativeName(message: message)
        let storage = cName(message)

        var members = AccessorSplitter.SplitAccessors()
        // plain fields in field-number order (matches nanopb's struct layout)
        for field in message.fields.sorted(by: { $0.number < $1.number })
            where field.realContainingOneof == nil
        {
            members.append(AccessorSplitter.split(emit(field, of: message)))
        }
        for oneof in Self.realOneofs(of: message) {
            members.append(AccessorSplitter.split(emit(oneof: oneof, of: message)))
        }

        var out = Self.messageHeader(type: type, storage: storage, pad: pad)
        for line in members.message {
            out += line.isEmpty ? "\n" : "\(pad)    \(line)\n"
        }
        for child in message.messages {
            out += emit(child, depth: depth + 1)
        }
        for enumType in message.enums {
            out += emit(enum: enumType, depth: depth + 1)
        }
        out += Self.builderHeader(type: type, pad: pad)
        for line in members.builder {
            out += line.isEmpty ? "\n" : "\(pad)        \(line)\n"
        }
        out += Self.factories(type: type, pad: pad)
        return out
    }

    private static func messageHeader(type: String, storage: String, pad: String) -> String {
        """
        \(pad)struct \(type): NanopbMessage, @unchecked Sendable {
        \(pad)    typealias Storage = \(storage)
        \(pad)    static var descriptor: pb_msgdesc_t { \(storage)_msg }
        \(pad)    static var zero: Storage { Storage() }

        \(pad)    var _owner: NanopbAnyBox
        \(pad)    var _pointer: UnsafeMutablePointer<Storage>

        \(pad)    init() {
        \(pad)        self.init(_owning: NanopbBox(zero: Self.zero, descriptor: Self.descriptor))
        \(pad)    }

        \(pad)    init(_owning box: NanopbBox<Storage>) {
        \(pad)        _owner = box
        \(pad)        _pointer = box.pointer
        \(pad)    }

        \(pad)    /// Zero-copy view into `owner`'s storage.
        \(pad)    init(_sharing pointer: UnsafeMutablePointer<Storage>, owner: NanopbAnyBox) {
        \(pad)        _owner = owner
        \(pad)        _pointer = pointer
        \(pad)    }


        """
    }

    private static func builderHeader(type: String, pad: String) -> String {
        """
        \(pad)    /// Mutation lives here. `~Copyable` means the compiler proves there is
        \(pad)    /// never a second live handle to this storage, so no uniqueness check is
        \(pad)    /// needed and `build()` publishes storage nothing can still mutate.
        \(pad)    struct Builder: ~Copyable {
        \(pad)        let _box: NanopbBox<Storage>
        \(pad)        var _owner: NanopbAnyBox { _box }
        \(pad)        var _pointer: UnsafeMutablePointer<Storage> { _box.pointer }

        \(pad)        init() { _box = NanopbBox(zero: \(type).zero, descriptor: \(type).descriptor) }
        \(pad)        init(_adopting box: NanopbBox<Storage>) { _box = box }
        \(pad)        consuming func build() -> \(type) { \(type)(_owning: _box) }


        """
    }

    private static func factories(type _: String, pad: String) -> String {
        """
        \(pad)    }

        \(pad)    static func with(_ populate: (inout Builder) throws -> Void) rethrows -> Self {
        \(pad)        var builder = Builder()
        \(pad)        try populate(&builder)
        \(pad)        return builder.build()
        \(pad)    }

        \(pad)    /// This message with `populate` applied. `consuming` ends the caller's
        \(pad)    /// ownership, so when nothing else holds the storage the mutation happens
        \(pad)    /// in place; otherwise it copies once for the whole batch, not per field.
        \(pad)    consuming func modifying(_ populate: (inout Builder) throws -> Void) rethrows -> Self {
        \(pad)        if _ownsItsStorage, isKnownUniquelyReferenced(&_owner) {
        \(pad)            var builder = Builder(_adopting: unsafeDowncast(_owner, to: NanopbBox<Storage>.self))
        \(pad)            try populate(&builder)
        \(pad)            return builder.build()
        \(pad)        }
        \(pad)        var builder = Builder()
        \(pad)        lkOverwrite(builder._pointer, with: self)
        \(pad)        try populate(&builder)
        \(pad)        return builder.build()
        \(pad)    }
        \(pad)}


        """
    }
}

struct ExemplarEmitter {
    let namer: SwiftProtobufNamer
    private let graph = TypeGraph()

    /// Message-reference graph for cycle-safe population: a message-typed
    /// field is left unset (in both builders) when setting it would recurse.
    final class TypeGraph {
        private var direct: [String: Set<String>] = [:]
        private var memo: [String: Set<String>] = [:]

        func add(_ message: Descriptor) {
            var refs: Set<String> = []
            for field in message.fields {
                if let target = Self.messageTarget(of: field) { refs.insert(target.fullName) }
            }
            direct[message.fullName] = refs
        }

        static func messageTarget(of field: FieldDescriptor) -> Descriptor? {
            if field.isMap {
                let value = field.messageType!.fields.first { $0.name == "value" }!
                return value.type == .message ? value.messageType : nil
            }
            return field.type == .message || field.type == .group ? field.messageType : nil
        }

        func reachable(from name: String) -> Set<String> {
            if let cached = memo[name] { return cached }
            var seen: Set<String> = []
            var queue = Array(direct[name] ?? [])
            while let next = queue.popLast() {
                guard seen.insert(next).inserted else { continue }
                queue += direct[next] ?? []
            }
            memo[name] = seen
            return seen
        }

        func createsCycle(_ field: FieldDescriptor, in container: Descriptor) -> Bool {
            guard let target = Self.messageTarget(of: field) else { return false }
            return target.fullName == container.fullName
                || reachable(from: target.fullName).contains(container.fullName)
        }
    }

    struct Output {
        var source = ""
        var messages = 0
        var oneofVariants = 0
    }

    func emit(files: [FileDescriptor], keep: Set<String>?) -> Output {
        var messages: [Descriptor] = []
        for file in files {
            for message in file.messages where keep?.contains(message.fullName) != false {
                collect(message, into: &messages)
            }
        }
        for message in messages {
            graph.add(message)
        }

        var out = Self.header
        var registry: [String] = []
        var variants: [String] = []
        for message in messages {
            out += builders(for: message)
            registry.append(registryEntry(for: message))
            variants += variantEntries(for: message)
        }
        out += "let conformanceExemplars: [ConformanceExemplar] = [\n"
        out += registry.joined()
        out += "]\n\nlet oneofVariantExemplars: [ConformanceExemplar] = [\n"
        out += variants.joined()
        out += "]\n"
        return Output(source: out, messages: messages.count, oneofVariants: variants.count)
    }

    /// Map entries are synthetic — nanopb needs their C structs, but
    /// protoc-gen-swift emits dictionaries, so there is no oracle type.
    private func collect(_ message: Descriptor, into list: inout [Descriptor]) {
        guard !message.options.mapEntry else { return }
        list.append(message)
        for child in message.messages {
            collect(child, into: &list)
        }
    }

    // MARK: naming

    private func mangled(_ message: Descriptor) -> String {
        Emitter.local(namer.fullName(message: message)).replacingOccurrences(of: ".", with: "_")
    }

    private func facadeType(_ message: Descriptor) -> String {
        "LiveKit.\(Emitter.local(namer.fullName(message: message)))"
    }

    /// The oracle type as protoc-gen-swift names it — well-known types stay
    /// module-qualified (SwiftProtobuf.Google_Protobuf_Timestamp).
    private func oracleType(_ message: Descriptor) -> String {
        namer.fullName(message: message)
    }

    private func propertyName(_ field: FieldDescriptor) -> String {
        namer.messagePropertyNames(field: field, prefixed: "", includeHasAndClear: false).name
    }

    private func builderCall(_ message: Descriptor, oracle: Bool) -> String {
        "\(oracle ? "oracleExemplar_" : "exemplar_")\(mangled(message))()"
    }

    // MARK: builders

    private func builders(for message: Descriptor) -> String {
        [false, true].map { oracle in
            let type = oracle ? oracleType(message) : facadeType(message)
            let name = builderCall(message, oracle: oracle).dropLast(2)
            let lines = assignments(for: message, oracle: oracle)
            guard !lines.isEmpty else { return "func \(name)() -> \(type) { \(type)() }\n\n" }
            // `with` exists on both sides — SwiftProtobuf's own builder for the
            // oracle, the generated one for the immutable facade
            return "func \(name)() -> \(type) {\n"
                + "    \(type).with { m in\n"
                + lines.map { "        \($0)\n" }.joined()
                + "    }\n}\n\n"
        }.joined()
    }

    private func assignments(for message: Descriptor, oracle: Bool) -> [String] {
        var lines: [String] = []
        for field in message.fields.sorted(by: { $0.number < $1.number })
            where field.realContainingOneof == nil
        {
            if let expr = valueExpr(for: field, in: message, oracle: oracle) {
                lines.append("m.\(propertyName(field)) = \(expr)")
            }
        }
        // one deterministic variant per oneof; every variant separately in
        // oneofVariantExemplars
        for oneof in Emitter.realOneofs(of: message) {
            let variants = oneof.fields.sorted { $0.number < $1.number }
            if let (variant, expr) = variants.lazy.compactMap({ variant in
                self.singularExpr(for: variant, in: message, oracle: oracle).map { (variant, $0) }
            }).first {
                lines.append("m.\(propertyName(variant)) = \(expr)")
            }
        }
        return lines
    }

    /// nil = leave the field unset (in both builders): recursive message,
    /// or an enum with no nonzero value to distinguish from the default.
    private func valueExpr(for field: FieldDescriptor, in message: Descriptor, oracle: Bool) -> String? {
        if field.isMap { return mapExpr(for: field, in: message, oracle: oracle) }
        if field.isRepeated { return repeatedExpr(for: field, in: message, oracle: oracle) }
        return singularExpr(for: field, in: message, oracle: oracle)
    }

    private func singularExpr(for field: FieldDescriptor, in message: Descriptor, oracle: Bool) -> String? {
        switch field.type {
        case .string: "\"\(field.name)\""
        case .bytes: "Data(\"\(field.name)\".utf8)"
        case .bool: "true"
        case .enum: enumCase(field.enumType!)
        case .message, .group:
            graph.createsCycle(field, in: message)
                ? nil : builderCall(field.messageType!, oracle: oracle)
        default: "\(field.number)"
        }
    }

    private func repeatedExpr(for field: FieldDescriptor, in message: Descriptor, oracle: Bool) -> String? {
        switch field.type {
        case .string: "[\"\(field.name)_0\", \"\(field.name)_1\"]"
        case .bool: "[true, false]"
        case .enum: enumCase(field.enumType!).map { "[\($0)]" }
        case .message, .group:
            graph.createsCycle(field, in: message)
                ? nil : "[\(builderCall(field.messageType!, oracle: oracle))]"
        case .bytes: "[Data(\"\(field.name)\".utf8)]"
        default: "[\(field.number), \(field.number + 1)]"
        }
    }

    private func mapExpr(for field: FieldDescriptor, in message: Descriptor, oracle: Bool) -> String? {
        let entry = field.messageType!
        let key = entry.fields.first { $0.name == "key" }!
        let value = entry.fields.first { $0.name == "value" }!
        let keyLit = switch key.type {
        case .string: "\"\(field.name)_key\""
        case .bool: "true"
        default: "\(field.number)"
        }
        // single entry: SwiftProtobuf map iteration order is undefined, so
        // multi-entry byte-identity cannot be asserted (see the map edge test)
        return singularExpr(for: value, in: message, oracle: oracle).map { "[\(keyLit): \($0)]" }
    }

    /// First nonzero enum case — proto3 skips zero-valued fields on the wire
    /// in SwiftProtobuf, while FT_POINTER presence would emit them.
    private func enumCase(_ enumType: EnumDescriptor) -> String? {
        namer.uniquelyNamedValues(enum: enumType)
            .first { $0.number != 0 }
            .map { ".\(namer.relativeName(enumValue: $0))" }
    }

    // MARK: registry

    private func registryEntry(for message: Descriptor) -> String {
        """
            ConformanceExemplar(
                name: "\(mangled(message))",
                facade: { try \(builderCall(message, oracle: false)).serializedData() },
                oracle: { try \(builderCall(message, oracle: true)).serializedData() },
                reencode: { try \(facadeType(message))(serializedData: $0).serializedData() },
            ),

        """
    }

    private func variantEntries(for message: Descriptor) -> [String] {
        var out: [String] = []
        for oneof in Emitter.realOneofs(of: message) {
            for variant in oneof.fields.sorted(by: { $0.number < $1.number }) {
                guard let facadeExpr = singularExpr(for: variant, in: message, oracle: false),
                      let oracleExpr = singularExpr(for: variant, in: message, oracle: true)
                else { continue }
                out.append("""
                    ConformanceExemplar(
                        name: "\(mangled(message)).\(oneof.name).\(propertyName(variant))",
                        facade: { try \(facadeType(message)).with { $0.\(propertyName(variant)) = \(facadeExpr) }.serializedData() },
                        oracle: { try \(oracleType(message)).with { $0.\(propertyName(variant)) = \(oracleExpr) }.serializedData() },
                        reencode: { try \(facadeType(message))(serializedData: $0).serializedData() },
                    ),

                """)
            }
        }
        return out
    }

    static let header = """
    // Generated by scripts/generate-swift-protos.swift — do not edit.
    //
    // Deterministic fully-populated exemplars of every facade message, built
    // through both implementations. See ExemplarConformanceTests.

    import Foundation
    @testable import LiveKit
    import LiveKitNanopb
    import SwiftProtobuf

    struct ConformanceExemplar: CustomStringConvertible, Sendable {
        let name: String
        /// Exemplar built and encoded through the nanopb facade.
        let facade: @Sendable () throws -> Data
        /// The same exemplar built and encoded through protoc-gen-swift.
        let oracle: @Sendable () throws -> Data
        /// Facade decode → encode of the given bytes.
        let reencode: @Sendable (Data) throws -> Data
        var description: String { name }
    }


    """
}

GenerateSwiftProtos.main()
