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

import ArgumentParser // apple/swift-argument-parser ~> 1.3
import Files // JohnSundell/Files ~> 4.2
import Foundation

// Run via: swiftly run +xcode swift-sh scripts/generate-facades.swift
//
// Emits Swift facades over nanopb's generated C structs.
//
// Ownership follows Firestore's `nanopb::Message<T>`: messages are `~Copyable`
// and either own their allocation or borrow a parent's. Nothing is deep-copied,
// which is why the runtime is ~12 KB rather than SwiftProtobuf's ~1.1 MB.
//
// Consequences for the emitted API, all forced by noncopyability:
//   * submessages are handed out through `withX { }` rather than returned
//   * repeated submessages are borrowed by index, with a separate count
//   * a oneof becomes a copyable *tag* enum plus per-variant accessors, because
//     an enum payload cannot be a borrowed noncopyable value
//
// Field and case names come from protoc-gen-swift's own output rather than
// reimplementing its camelCase + initialism rules: the reference .pb.swift files
// are parsed and matched by normalised name.

struct GenerateFacades: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate move-only Swift facades over nanopb C structs.",
    )

    @Option(help: "Directory holding nanopb's generated livekit_*.pb.h headers.")
    var headers = "Sources/CLiveKitProto/include"

    @Option(help: "Directory holding protoc-gen-swift's .pb.swift output, used only for naming.")
    var reference = "Tests/LiveKitNanopbTests/Oracle"

    @Option(help: "Where to write the generated facades.")
    var output = "Sources/LiveKit/Protos"

    @Flag(inversion: .prefixedNo, help: "Emit facades only for types reachable from SDK code.")
    var prune = true

    func run() throws {
        var names = try Naming(referenceDirectory: reference)
        let outFolder = try Folder(path: output)
        var stats = Stats()

        // Pass 1: parse every header. Enums are declared in one header but
        // referenced from others, so the enum set must be global first.
        var allHeaders = try Folder(path: headers).files
            .filter { $0.name.hasPrefix("livekit_") && $0.name.hasSuffix(".pb.h") }
            .sorted { $0.name < $1.name }
        if let wkt = try? Folder(path: headers).subfolder(at: "google/protobuf")
            .file(named: "timestamp.pb.h")
        {
            allHeaders.append(wkt)
        }
        var globalEnums: Set<String> = []
        var texts: [String: String] = [:]
        for header in allHeaders {
            let text = try header.readAsString()
            texts[header.name] = text
            globalEnums.formUnion(CHeaderParser(text: text).declaredEnums())
        }
        var parsedByHeader: [String: ParsedHeader] = [:]
        var allMessages: [String: CMessage] = [:]
        for header in allHeaders {
            let parsed = try CHeaderParser(text: texts[header.name]!).parse(knownEnums: globalEnums)
            parsedByHeader[header.name] = parsed
            for message in parsed.messages {
                allMessages[message.cName] = message
            }
        }
        names.messageCNames = Set(allMessages.keys)

        // Facades are pure API surface — the C tables carry the wire format for
        // every field regardless — so pruning to the SDK's reachability closure
        // cannot affect round-tripping of unpruned data.
        let keep = prune
            ? Reachability(messages: allMessages, names: names).closure(
                from: usedTypeNames(), enums: globalEnums,
            )
            : nil

        for header in allHeaders {
            let parsed = parsedByHeader[header.name]!
            let tree = MessageTree(parsed: parsed, names: names)
            let emitter = Emitter(
                names: names, tree: tree, headerText: texts[header.name]!,
                declaredEnums: parsed.declared, byName: allMessages,
            )

            var body = Self.fileHeader
            for root in tree.roots where keep?.messages.contains(root.cName) != false {
                body += emitter.emit(root, depth: 0)
                stats.add(tree, root)
            }
            for cEnum in parsed.declared.sorted() where !names.isNested(cEnum) {
                if keep?.enums.contains(cEnum) == false { continue }
                body += emitter.emit(enum: cEnum, depth: 0)
                stats.enums += 1
            }

            let stem = header.name.replacingOccurrences(of: ".pb.h", with: "")
            let file = try outFolder.createFile(named: "\(stem)+Nanopb.swift")
            try file.write(body)
        }

        let pruned = keep.map { allMessages.count - $0.messages.count } ?? 0
        // Self-check: every emitted mutation path must uphold the copy-on-write
        // invariant that justifies `@unchecked Sendable` on NanopbBox. A setter
        // that skips _ensureUnique() would mutate storage shared across values
        // (and potentially tasks) — fail generation, not the user.
        try Self.verifyCoWInvariant(in: outFolder)

        print("""
        messages : \(stats.messages)  (nested: \(stats.nested), pruned top-level: \(pruned))
        enums    : \(stats.enums)
        fields   : \(stats.fields)
        oneofs   : \(stats.oneofs)
        output   : \(output)
        """)
    }

    /// Type names spelled anywhere in hand-written SDK or test code.
    private func usedTypeNames() -> Set<String> {
        var used: Set<String> = []
        let roots = ["Sources/LiveKit", "Tests"]
        for root in roots {
            guard let folder = try? Folder(path: root) else { continue }
            for file in folder.files.recursive where file.name.hasSuffix(".swift") {
                let path = file.path
                if path.contains("/Protos/") || path.contains("/Oracle/") { continue }
                guard let text = try? file.readAsString() else { continue }
                for m in Naming.typeReferences(in: text) {
                    used.insert(m)
                }
            }
        }
        return used
    }

    static func verifyCoWInvariant(in folder: Folder) throws {
        var violations: [String] = []
        for file in folder.files where file.name.hasSuffix("+Nanopb.swift") {
            let lines = try file.readAsString().components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                if line.contains("nonmutating set") {
                    violations.append("\(file.name):\(index + 1): nonmutating set")
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed == "set {" || trimmed.hasPrefix("set { ") else { continue }
                let rest = trimmed.dropFirst("set {".count).trimmingCharacters(in: .whitespaces)
                let next = rest.isEmpty
                    ? (index + 1 < lines.count
                        ? lines[index + 1].trimmingCharacters(in: .whitespaces) : "")
                    : rest
                if !next.hasPrefix("_ensureUnique()") {
                    violations.append("\(file.name):\(index + 1): setter without _ensureUnique()")
                }
            }
        }
        guard violations.isEmpty else {
            throw ValidationError("""
            Generated setters violate the copy-on-write invariant:
            \(violations.joined(separator: "\n"))
            """)
        }
    }

    static let fileHeader = """
    // Generated by scripts/generate-facades.swift — do not edit.
    //
    // Move-only facades over nanopb's C structs. See Sources/LiveKitNanopb.

    import CLiveKitProto
    import Foundation
    import LiveKitNanopb


    """
}

// MARK: - Model

struct CField {
    enum Kind { case string, bytes, scalar, `enum`, message, oneof }

    var name: String
    var cType: String
    var kind: Kind
    /// True when nanopb stored this as a pointer (FT_POINTER) rather than inline.
    var isPointer = false
    var isRepeated = false
    /// nanopb emitted a `has_<name>` flag for this field.
    var hasFlag = false
    var variants: [CField] = []
}

struct CMessage {
    var cName: String
    var fields: [CField]
}

struct ParsedHeader {
    var messages: [CMessage]
    /// Enums declared in *this* header (drives where they are emitted).
    var declared: Set<String>
    /// Every enum name known across all headers (drives field classification).
    var enums: Set<String>
}

struct Stats {
    var messages = 0, nested = 0, enums = 0, fields = 0, oneofs = 0

    mutating func add(_ tree: MessageTree, _ message: CMessage) {
        messages += 1
        fields += message.fields.count
        oneofs += message.fields.count { $0.kind == .oneof }
        for child in tree.children(of: message.cName) {
            nested += 1
            add(tree, child)
        }
    }
}

/// Groups messages by nesting parent so nested declarations are emitted inside
/// the type that owns them, as protoc-gen-swift does.
struct MessageTree {
    private var byName: [String: CMessage] = [:]
    private var childrenByParent: [String: [CMessage]] = [:]
    var roots: [CMessage] = []

    init(parsed: ParsedHeader, names: Naming) {
        for message in parsed.messages {
            byName[message.cName] = message
        }
        for message in parsed.messages {
            if let parent = names.parent(of: message.cName), byName[parent] != nil {
                childrenByParent[parent, default: []].append(message)
            } else {
                roots.append(message)
            }
        }
    }

    func children(of cName: String) -> [CMessage] {
        childrenByParent[cName]?.sorted { $0.cName < $1.cName } ?? []
    }
}

// MARK: - Naming

struct Naming {
    /// C names of every parsed message, for structural nesting detection.
    var messageCNames: Set<String> = []
    private var properties: [String: String] = [:]
    private var cases: [String: String] = [:]
    private var types: Set<String> = []

    init(referenceDirectory: String) throws {
        for file in try Folder(path: referenceDirectory).files
            where file.name.hasSuffix(".pb.swift")
        {
            let text = try file.readAsString()
            for name in Self.matches(in: text, pattern: #"\bvar\s+([A-Za-z_]\w*)\s*:"#) {
                properties[Self.normalise(name)] = properties[Self.normalise(name)] ?? name
            }
            for name in Self.matches(in: text, pattern: #"\bcase\s+([a-zA-Z]\w*)"#) {
                cases[Self.normalise(name)] = cases[Self.normalise(name)] ?? name
            }
            types.formUnion(
                Self.matches(in: text, pattern: #"\b(?:struct|enum)\s+(Livekit_[A-Za-z0-9_]+)"#),
            )
        }
    }

    func property(_ cName: String) -> String {
        Self.escaping(properties[Self.normalise(cName)] ?? Self.camelCase(cName))
    }

    /// A proto field may be named after a Swift keyword (e.g. `protocol`).
    static func escaping(_ identifier: String) -> String {
        keywords.contains(identifier) ? "`\(identifier)`" : identifier
    }

    private static let keywords: Set<String> = [
        "protocol", "class", "struct", "enum", "func", "var", "let", "return", "default",
        "internal", "public", "private", "static", "operator", "extension", "import",
        "where", "repeat", "in", "is", "as", "self", "super", "true", "false", "nil",
    ]

    func enumCase(_ cName: String) -> String {
        cases[Self.normalise(cName)] ?? Self.camelCase(cName.lowercased())
    }

    /// protoc-gen-swift strips the enum-name prefix from value names
    /// (`METRIC_LABEL_PREDEFINED_MAX_VALUE` -> `predefinedMaxValue`). Try the
    /// oracle with progressively shorter suffixes before falling back.
    func enumValueCase(_ raw: String) -> String {
        var parts = raw.split(separator: "_").map(String.init)
        while !parts.isEmpty {
            if let known = cases[Self.normalise(parts.joined())] { return known }
            parts.removeFirst()
        }
        return Self.camelCase(raw.lowercased())
    }

    /// The C name of the type this one nests inside, if any. Structural check
    /// against the parsed message set first (handles multi-level nesting the
    /// oracle cannot see), oracle types as fallback.
    func parent(of cName: String) -> String? {
        let parts = cName.split(separator: "_").map(String.init)
        guard parts.count > 2 else { return nil }
        for split in stride(from: parts.count - 1, through: 2, by: -1) {
            let candidate = parts[..<split].joined(separator: "_")
            if messageCNames.contains(candidate) { return candidate }
            if types.contains(Self.flatSwiftName(candidate)) { return candidate }
        }
        return nil
    }

    /// `livekit_DataStream_Header` -> `Header` when nested, else `Livekit_DataStream`.
    func localName(_ cName: String) -> String {
        guard let parent = parent(of: cName) else { return Self.flatSwiftName(cName) }
        let local = cName.dropFirst(parent.count + 1)
            .split(separator: "_").map(\.capitalizedFirst).joined()
        // `Type` is Swift's metatype keyword; protoc-gen-swift emits `TypeEnum`.
        return Self.reserved.contains(local) ? "\(local)Enum" : local
    }

    private static let reserved: Set<String> = ["Type", "Self", "Protocol", "Any"]

    /// Fully-qualified Swift name, e.g. `Livekit_DataStream.Header`.
    func swiftType(_ cName: String) -> String {
        guard let parent = parent(of: cName) else { return Self.flatSwiftName(cName) }
        return "\(swiftType(parent)).\(localName(cName))"
    }

    func isNested(_ cName: String) -> Bool { parent(of: cName) != nil }

    private static func flatSwiftName(_ cName: String) -> String {
        let parts = cName.split(separator: "_").map(String.init)
        // google.protobuf.* keeps protoc-gen-swift's underscored spelling.
        if parts.count >= 3, parts[0] == "google", parts[1] == "protobuf" {
            return "Google_Protobuf_" + parts[2...].map(\.capitalizedFirst).joined()
        }
        return "Livekit_" + parts.dropFirst().map(\.capitalizedFirst).joined()
    }

    private static func normalise(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func camelCase(_ s: String) -> String {
        let parts = s.split(separator: "_").map { $0.lowercased() }
        guard let first = parts.first else { return s }
        return first + parts.dropFirst().map(\.capitalizedFirst).joined()
    }

    fileprivate static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// `Livekit_X` / `Google_Protobuf_X` identifiers spelled in source.
    static func typeReferences(in text: String) -> [String] {
        matches(in: text, pattern: #"\b((?:Livekit|Google_Protobuf)_[A-Za-z0-9_]+)"#)
    }
}

/// Computes which top-level messages/enums are reachable from the SDK's own code.
struct Reachability {
    let messages: [String: CMessage]
    let names: Naming

    struct Keep {
        var messages: Set<String> // top-level cNames
        var enums: Set<String> // top-level enum cNames
    }

    func closure(from usedSwiftNames: Set<String>, enums: Set<String>) -> Keep {
        // top-level cName -> flat swift name
        func topLevel(_ cName: String) -> String {
            var current = cName
            while let parent = names.parent(of: current) {
                current = parent
            }
            return current
        }
        var bySwift: [String: String] = [:]
        for cName in messages.keys where names.parent(of: cName) == nil {
            bySwift[names.swiftType(cName)] = cName
        }
        var queue = usedSwiftNames.compactMap { bySwift[$0] }
        var kept = Set(queue)
        while let cName = queue.popLast() {
            // walk this top-level and all its nested messages
            let family = messages.values.filter { topLevel($0.cName) == cName }
            for message in family {
                for field in message.fields {
                    let targets = field.kind == .oneof
                        ? field.variants.filter { $0.kind == .message }.map(\.cType)
                        : (field.kind == .message ? [field.cType] : [])
                    for target in targets where messages[target] != nil {
                        let top = topLevel(target)
                        if kept.insert(top).inserted { queue.append(top) }
                    }
                }
            }
        }
        // enums: named directly, or referenced by any kept message family
        var keptEnums = Set(enums.filter { usedSwiftNames.contains(names.swiftType($0)) })
        for message in messages.values where kept.contains(topLevel(message.cName)) {
            for field in message.fields {
                if field.kind == .enum { keptEnums.insert(field.cType) }
                for variant in field.variants where variant.kind == .enum {
                    keptEnums.insert(variant.cType)
                }
            }
        }
        // nested enums are emitted with their parent regardless; keep set is top-level only
        keptEnums = Set(keptEnums.filter { names.parent(of: $0) == nil })
        return Keep(messages: kept, enums: keptEnums)
    }
}

extension StringProtocol {
    var capitalizedFirst: String { isEmpty ? String(self) : prefix(1).uppercased() + dropFirst() }
}

// MARK: - C header parsing

struct CHeaderParser {
    static let scalars: [String: (swift: String, zero: String)] = [
        "bool": ("Bool", "false"), "int32_t": ("Int32", "0"), "int64_t": ("Int64", "0"),
        "uint32_t": ("UInt32", "0"), "uint64_t": ("UInt64", "0"),
        "float": ("Float", "0"), "double": ("Double", "0"),
    ]

    let text: String

    func declaredEnums() -> Set<String> {
        Set(Self.captures(in: Self.stripComments(text), pattern: #"typedef enum _(\w+) \{"#))
    }

    func parse(knownEnums: Set<String>) throws -> ParsedHeader {
        let stripped = Self.stripComments(text)
        // A pb_callback_t field means the .options file is missing an
        // FT_POINTER entry — nanopb would silently skip the field on decode.
        let callbacks = Self.captures(in: stripped, pattern: #"pb_callback_t (\w+);"#)
        guard callbacks.isEmpty else {
            throw ValidationError("""
            nanopb emitted callback fields (data would be silently dropped): \(callbacks.joined(separator: ", ")).
            Add `type:FT_POINTER` entries for them in scripts/proto-options/*.options and re-run make proto.
            """)
        }
        let declared = declaredEnums()
        var messages: [CMessage] = []
        for (name, body) in Self.structBodies(in: stripped) {
            messages.append(CMessage(cName: name, fields: Self.fields(in: body, enums: knownEnums)))
        }
        return ParsedHeader(messages: messages, declared: declared, enums: knownEnums)
    }

    static func stripComments(_ text: String) -> String {
        text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: [.regularExpression])
    }

    /// Enum values in declaration order, with nanopb's `<CEnum>_` prefix removed.
    static func enumValues(in text: String, cEnum: String) -> [(name: String, value: Int)] {
        let stripped = stripComments(text)
        guard let regex = try? NSRegularExpression(
            pattern: "typedef enum _\(cEnum) \\{([\\s\\S]*?)\\} \(cEnum);",
        ),
            let match = regex.firstMatch(
                in: stripped,
                range: NSRange(stripped.startIndex ..< stripped.endIndex, in: stripped),
            ),
            let bodyRange = Range(match.range(at: 1), in: stripped)
        else { return [] }
        var out: [(String, Int)] = []
        for line in stripped[bodyRange].split(separator: ",") {
            let parts = line.split(separator: "=")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, let value = Int(parts[1]) else { continue }
            let short = parts[0].hasPrefix("\(cEnum)_")
                ? String(parts[0].dropFirst(cEnum.count + 1)) : parts[0]
            out.append((short, value))
        }
        return out
    }

    private static func structBodies(in text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        guard let regex = try? NSRegularExpression(
            pattern: #"typedef struct _(\w+) \{([\s\S]*?)\n\} \1;"#,
        ) else { return out }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let n = Range(match.range(at: 1), in: text),
                  let b = Range(match.range(at: 2), in: text) else { continue }
            out.append((String(text[n]), String(text[b])))
        }
        return out
    }

    private static func fields(in body: String, enums: Set<String>) -> [CField] {
        let lines = body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out: [CField] = []
        var pendingHasFlag: String?
        var i = 0
        while i < lines.count {
            let line = lines[i]

            if let flag = capture(line, #"^bool has_(\w+);$"#) {
                pendingHasFlag = flag
                i += 1
                continue
            }
            if let which = capture(line, #"^pb_size_t which_(\w+);$"#) {
                i += 1
                var variants: [CField] = []
                while i < lines.count, !lines[i].hasPrefix("}") {
                    if let v = field(from: lines[i], enums: enums) { variants.append(v) }
                    i += 1
                }
                out.append(CField(name: which, cType: "", kind: .oneof, variants: variants))
                i += 1
                continue
            }
            if capture(line, #"^pb_size_t (\w+)_count;$"#) != nil, i + 1 < lines.count,
               var f = field(from: lines[i + 1], enums: enums)
            {
                f.isRepeated = true
                out.append(f)
                i += 2
                continue
            }
            if var f = field(from: line, enums: enums) {
                if pendingHasFlag == f.name { f.hasFlag = true }
                out.append(f)
            }
            pendingHasFlag = nil
            i += 1
        }
        return out
    }

    private static func field(from line: String, enums: Set<String>) -> CField? {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
        guard !trimmed.isEmpty, !trimmed.hasPrefix("union"), !trimmed.hasPrefix("}"),
              !trimmed.hasPrefix("pb_size_t"), !trimmed.hasPrefix("bool has_"),
              !trimmed.hasPrefix("pb_callback_t")
        else { return nil }
        guard let regex = try? NSRegularExpression(
            pattern: #"^(?:struct _)?(\w+)\s*(\*{0,2})\s*(\w+)$"#,
        ),
            let m = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex ..< trimmed.endIndex, in: trimmed),
            ),
            let t = Range(m.range(at: 1), in: trimmed),
            let n = Range(m.range(at: 3), in: trimmed)
        else { return nil }
        let cType = String(trimmed[t])
        let name = String(trimmed[n])
        guard name != "dummy_field" else { return nil }
        let kind: CField.Kind = switch cType {
        case "char": .string
        case "pb_bytes_array_t": .bytes
        default:
            if scalars[cType] != nil {
                .scalar
            } else if enums.contains(cType) {
                .enum
            } else {
                .message
            }
        }
        return CField(name: name, cType: cType, kind: kind, isPointer: trimmed.contains("*"))
    }

    private static func capture(_ s: String, _ pattern: String) -> String? {
        captures(in: s, pattern: pattern).first
    }

    fileprivate static func captures(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}

// MARK: - Emission

struct Emitter {
    let names: Naming
    let tree: MessageTree
    let headerText: String
    /// Enums declared in this header, so nested ones are emitted in-place.
    let declaredEnums: Set<String>
    /// Every parsed message across all headers (map-entry lookups).
    let byName: [String: CMessage]

    private func nestedEnums(of cName: String) -> [String] {
        declaredEnums.filter { names.parent(of: $0) == cName }.sorted()
    }

    /// A map<K,V> field compiles to a repeated `<Field>Entry` message with
    /// exactly `key` and `value` fields.
    private func mapEntry(_ field: CField) -> CMessage? {
        guard field.isRepeated, field.kind == .message, field.cType.hasSuffix("Entry"),
              let entry = byName[field.cType],
              entry.fields.map(\.name).sorted() == ["key", "value"]
        else { return nil }
        return entry
    }

    func emit(_ message: CMessage, depth: Int) -> String {
        let pad = String(repeating: "    ", count: depth)
        let type = names.localName(message.cName)
        var out = """
        \(pad)struct \(type): NanopbMessage, @unchecked Sendable {
        \(pad)    typealias Storage = \(message.cName)
        \(pad)    static var descriptor: pb_msgdesc_t { \(message.cName)_msg }
        \(pad)    static var zero: Storage { Storage() }

        \(pad)    var _owner: AnyObject
        \(pad)    var _pointer: UnsafeMutablePointer<Storage>

        \(pad)    init() {
        \(pad)        let box = NanopbBox(zero: Self.zero, descriptor: Self.descriptor)
        \(pad)        _owner = box
        \(pad)        _pointer = box.pointer
        \(pad)    }

        \(pad)    /// Zero-copy view into `owner`'s storage.
        \(pad)    init(_sharing pointer: UnsafeMutablePointer<Storage>, owner: AnyObject) {
        \(pad)        _owner = owner
        \(pad)        _pointer = pointer
        \(pad)    }


        """
        for field in message.fields {
            for line in emit(field, of: message) {
                out += "\(pad)    \(line)\n"
            }
            out += "\n"
        }
        for child in tree.children(of: message.cName) {
            out += emit(child, depth: depth + 1)
        }
        for nested in nestedEnums(of: message.cName) {
            out += emit(enum: nested, depth: depth + 1)
        }
        out += "\(pad)}\n\n"
        return out
    }

    // MARK: fields

    private func emit(_ field: CField, of message: CMessage) -> [String] {
        if field.kind == .oneof { return emitOneOf(field, of: message) }
        if field.isRepeated { return emitRepeated(field) }

        let property = names.property(field.name)
        let capitalised = property.replacingOccurrences(of: "`", with: "").capitalizedFirst
        let slot = "_pointer.pointee.\(Naming.escaping(field.name))"

        switch field.kind {
        case .string:
            return [
                "var \(property): String {",
                "    get { lkString(\(slot)) ?? \"\" }",
                "    set { _ensureUnique(); lkSetString(&\(slot), newValue) }",
                "}",
                "var has\(capitalised): Bool { \(slot) != nil }",
                "/// Zero-copy read — borrows nanopb's allocation for the call only.",
                "func with\(capitalised)Bytes<R>(_ body: (UnsafeRawBufferPointer?) throws -> R) rethrows -> R {",
                "    try withLkBytes(\(slot), body)",
                "}",
            ]
        case .bytes:
            return [
                "var \(property): Data {",
                "    get { lkData(\(slot)) }",
                "    set { _ensureUnique(); lkSetData(&\(slot), newValue) }",
                "}",
                "var has\(capitalised): Bool { \(slot) != nil }",
                "func with\(capitalised)<R>(_ body: (UnsafeRawBufferPointer?) throws -> R) rethrows -> R {",
                "    try withLkData(\(slot), body)",
                "}",
            ]
        case .scalar:
            let scalar = CHeaderParser.scalars[field.cType]!
            var lines = ["var \(property): \(scalar.swift) {"]
            lines.append(field.isPointer
                ? "    get { \(slot)?.pointee ?? \(scalar.zero) }"
                : "    get { \(slot) }")
            lines.append(field.isPointer
                ? "    set { _ensureUnique(); lkSetValue(&\(slot), newValue) }"
                : "    set { _ensureUnique(); \(slot) = newValue }")
            lines.append("}")
            lines += presence(field, capitalised: capitalised, slot: slot)
            return lines
        case .enum:
            let type = names.swiftType(field.cType)
            var lines = ["var \(property): \(type) {"]
            lines.append(field.isPointer
                ? "    get { \(slot).map { lkEnum($0.pointee) } ?? \(type)() }"
                : "    get { lkEnum(\(slot)) }")
            lines.append(field.isPointer
                ? "    set { _ensureUnique(); lkSetEnumPointer(&\(slot), newValue) }"
                : "    set { _ensureUnique(); lkSetEnum(&\(slot), newValue) }")
            lines.append("}")
            lines += presence(field, capitalised: capitalised, slot: slot)
            return lines
        case .message:
            let type = names.swiftType(field.cType)
            var lines = ["var \(property): \(type) {"]
            if field.isPointer {
                lines.append("    get { \(slot).map { \(type)(_sharing: $0, owner: _owner) } ?? \(type)() }")
                lines.append("    set { _ensureUnique(); lkSetMessage(&\(slot), newValue) }")
            } else {
                lines.append("    get { \(type)(_sharing: lkMemberPointer(_pointer, \\Storage.\(Naming.escaping(field.name))), owner: _owner) }")
                if field.hasFlag {
                    lines.append("    set { _ensureUnique(); lkSetMessage(inline: &\(slot), newValue); _pointer.pointee.has_\(field.name) = true }")
                } else {
                    lines.append("    set { _ensureUnique(); lkSetMessage(inline: &\(slot), newValue) }")
                }
            }
            lines.append("}")
            lines += presence(field, capitalised: capitalised, slot: slot)
            return lines
        case .oneof:
            return []
        }
    }

    private func presence(_ field: CField, capitalised: String, slot: String) -> [String] {
        if field.hasFlag {
            return ["var has\(capitalised): Bool { _pointer.pointee.has_\(field.name) }"]
        }
        if field.isPointer {
            return ["var has\(capitalised): Bool { \(slot) != nil }"]
        }
        return []
    }

    private func emitRepeated(_ field: CField) -> [String] {
        let property = names.property(field.name)
        let count = "_pointer.pointee.\(field.name)_count"
        let base = "_pointer.pointee.\(Naming.escaping(field.name))"

        if let entry = mapEntry(field) {
            return emitMap(field, entry: entry, property: property, count: count, base: base)
        }
        switch field.kind {
        case .string:
            return [
                "var \(property): [String] {",
                "    get { lkRepeated(\(count), \(base)) }",
                "    set {",
                "        _ensureUnique()",
                "        var count = \(count), base = \(base)",
                "        lkSetRepeated(&count, &base, newValue)",
                "        \(count) = count; \(base) = base",
                "    }",
                "}",
            ]
        case .scalar:
            let scalar = CHeaderParser.scalars[field.cType]!
            return [
                "var \(property): [\(scalar.swift)] {",
                "    get { lkRepeated(\(count), \(base)) }",
                "    set {",
                "        _ensureUnique()",
                "        var count = \(count), base = \(base)",
                "        lkSetRepeated(&count, &base, newValue)",
                "        \(count) = count; \(base) = base",
                "    }",
                "}",
            ]
        case .enum:
            let type = names.swiftType(field.cType)
            return [
                "var \(property): [\(type)] {",
                "    get { lkRepeatedEnum(\(count), \(base)) }",
                "    set {",
                "        _ensureUnique()",
                "        var count = \(count), base = \(base)",
                "        lkSetRepeatedEnum(&count, &base, newValue)",
                "        \(count) = count; \(base) = base",
                "    }",
                "}",
            ]
        default:
            let type = names.swiftType(field.cType)
            return [
                "var \(property): [\(type)] {",
                "    get { lkViews(\(count), \(base), owner: _owner) }",
                "    set {",
                "        _ensureUnique()",
                "        var count = \(count), base = \(base)",
                "        lkSetRepeatedMessages(&count, &base, newValue)",
                "        \(count) = count; \(base) = base",
                "    }",
                "}",
            ]
        }
    }

    private func emitMap(
        _: CField, entry: CMessage, property: String, count: String, base: String,
    ) -> [String] {
        let entryType = names.swiftType(entry.cName)
        let keyField = entry.fields.first { $0.name == "key" }!
        let keyType: String = switch keyField.kind {
        case .string: "String"
        case .scalar: CHeaderParser.scalars[keyField.cType]!.swift
        default: "String"
        }
        let valueField = entry.fields.first { $0.name == "value" }!
        let valueType: String = switch valueField.kind {
        case .string: "String"
        case .bytes: "Data"
        case .scalar: CHeaderParser.scalars[valueField.cType]!.swift
        case .enum, .message: names.swiftType(valueField.cType)
        case .oneof: "Never"
        }
        return [
            "var \(property): [\(keyType): \(valueType)] {",
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

    // MARK: oneofs — protoc-gen-swift's `OneOf_X` enum-with-payload shape

    private func emitOneOf(_ field: CField, of message: CMessage) -> [String] {
        let property = names.property(field.name)
        let capitalised = property.replacingOccurrences(of: "`", with: "").capitalizedFirst
        let enumName = "OneOf_\(capitalised)"
        let which = "_pointer.pointee.which_\(field.name)"

        var out = ["enum \(enumName): Equatable {"]
        for variant in field.variants {
            out.append("    case \(names.enumCase(variant.name))(\(payloadType(variant)))")
        }
        out.append("}")
        out.append("")

        // the oneof property
        out.append("var \(property): \(enumName)? {")
        out.append("    get {")
        out.append("        switch \(which) {")
        for variant in field.variants {
            out.append("        case pb_size_t(\(message.cName)_\(variant.name)_tag):")
            out.append("            return .\(names.enumCase(variant.name))(\(read(variant, in: field)))")
        }
        out.append("        default: return nil")
        out.append("        }")
        out.append("    }")
        out.append("    set {")
        out.append("        _ensureUnique()")
        out.append("        _clear\(capitalised)()")
        out.append("        switch newValue {")
        for variant in field.variants {
            out.append("        case let .\(names.enumCase(variant.name))(value):")
            out.append("            \(which) = pb_size_t(\(message.cName)_\(variant.name)_tag)")
            out.append("            \(write(variant, in: field, from: "value"))")
        }
        out.append("        case nil: break")
        out.append("        }")
        out.append("    }")
        out.append("}")
        out.append("")

        // direct per-variant accessors, as protoc-gen-swift emits
        for variant in field.variants {
            let vProperty = names.property(variant.name) // may be backticked
            let vType = payloadType(variant)
            out.append("var \(vProperty): \(vType) {")
            out.append("    get { \(which) == pb_size_t(\(message.cName)_\(variant.name)_tag) ? (\(read(variant, in: field))) : \(defaultValue(variant)) }")
            out.append("    set {")
            out.append("        _ensureUnique()")
            out.append("        _clear\(capitalised)()")
            out.append("        \(which) = pb_size_t(\(message.cName)_\(variant.name)_tag)")
            out.append("        \(write(variant, in: field, from: "newValue"))")
            out.append("    }")
            out.append("}")
        }
        out.append("")

        // release the live variant with the right layout before switching
        out.append("private mutating func _clear\(capitalised)() {")
        out.append("    switch \(which) {")
        for variant in field.variants {
            let slot = "_pointer.pointee.\(field.name).\(Naming.escaping(variant.name))"
            out.append("    case pb_size_t(\(message.cName)_\(variant.name)_tag):")
            switch variant.kind {
            case .message:
                out.append("        lkRelease(message: &\(slot), \(names.swiftType(variant.cType)).descriptor)")
            case .string, .bytes:
                out.append("        lkFree(&\(slot))")
            default:
                out.append(variant.isPointer ? "        lkFree(&\(slot))" : "        break")
            }
        }
        out.append("    default: break")
        out.append("    }")
        out.append("    \(which) = 0")
        out.append("    // zero the union: stale bits from an inline variant would otherwise")
        out.append("    // be misread as a pointer by the next variant's setter")
        out.append("    _pointer.pointee.\(field.name) = .init()")
        out.append("}")
        return out
    }

    private func read(_ variant: CField, in oneof: CField) -> String {
        let slot = "_pointer.pointee.\(oneof.name).\(Naming.escaping(variant.name))"
        switch variant.kind {
        case .string: return "lkString(\(slot)) ?? \"\""
        case .bytes: return "lkData(\(slot))"
        case .scalar:
            let scalar = CHeaderParser.scalars[variant.cType]!
            return variant.isPointer ? "\(slot)?.pointee ?? \(scalar.zero)" : slot
        case .enum:
            let type = names.swiftType(variant.cType)
            return variant.isPointer
                ? "\(slot).map { lkEnum($0.pointee) as \(type) } ?? \(type)()"
                : "lkEnum(\(slot))"
        default:
            let type = names.swiftType(variant.cType)
            return "\(slot).map { \(type)(_sharing: $0, owner: _owner) } ?? \(type)()"
        }
    }

    private func write(_ variant: CField, in oneof: CField, from source: String) -> String {
        let slot = "_pointer.pointee.\(oneof.name).\(Naming.escaping(variant.name))"
        switch variant.kind {
        case .string: return "lkSetString(&\(slot), \(source))"
        case .bytes: return "lkSetData(&\(slot), \(source))"
        case .scalar:
            return variant.isPointer
                ? "lkSetValue(&\(slot), \(source))" : "\(slot) = \(source)"
        case .enum:
            return variant.isPointer
                ? "lkSetEnumPointer(&\(slot), \(source))" : "lkSetEnum(&\(slot), \(source))"
        default: return "lkSetMessage(&\(slot), \(source))"
        }
    }

    private func payloadType(_ variant: CField) -> String {
        switch variant.kind {
        case .string: "String"
        case .bytes: "Data"
        case .scalar: CHeaderParser.scalars[variant.cType]!.swift
        default: names.swiftType(variant.cType)
        }
    }

    private func defaultValue(_ variant: CField) -> String {
        switch variant.kind {
        case .string: "\"\""
        case .bytes: "Data()"
        case .scalar: CHeaderParser.scalars[variant.cType]!.zero
        default: "\(names.swiftType(variant.cType))()"
        }
    }

    // MARK: enums

    func emit(enum cEnum: String, depth: Int) -> String {
        let pad = String(repeating: "    ", count: depth)
        let type = names.localName(cEnum)
        let values = CHeaderParser.enumValues(in: headerText, cEnum: cEnum)
        let first = values.first.map { names.enumValueCase($0.name) } ?? "unknown"

        var out = "\(pad)enum \(type): NanopbEnum, CaseIterable {\n"
        for value in values {
            out += "\(pad)    case \(names.enumValueCase(value.name))\n"
        }
        out += "\(pad)    case UNRECOGNIZED(Int)\n\n"
        out += "\(pad)    init() { self = .\(first) }\n\n"
        out += "\(pad)    init?(rawValue: Int) {\n\(pad)        switch rawValue {\n"
        for value in values {
            out += "\(pad)        case \(value.value): self = .\(names.enumValueCase(value.name))\n"
        }
        out += "\(pad)        default: self = .UNRECOGNIZED(rawValue)\n"
        out += "\(pad)        }\n\(pad)    }\n\n"
        out += "\(pad)    var rawValue: Int {\n\(pad)        switch self {\n"
        for value in values {
            out += "\(pad)        case .\(names.enumValueCase(value.name)): \(value.value)\n"
        }
        out += "\(pad)        case let .UNRECOGNIZED(value): value\n"
        out += "\(pad)        }\n\(pad)    }\n\n"
        out += "\(pad)    static var allCases: [\(type)] {\n\(pad)        ["
        out += values.map { ".\(names.enumValueCase($0.name))" }.joined(separator: ", ")
        out += "]\n\(pad)    }\n"
        out += "\(pad)}\n\n"
        return out
    }
}

GenerateFacades.main()
