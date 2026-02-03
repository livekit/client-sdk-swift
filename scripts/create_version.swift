#!/usr/bin/env swift

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

/// Change file format:
/// Each line in a change file should follow the format:
/// `level type="kind" "description"`
///
/// Where:
/// - level: One of [patch, minor, major] indicating the version bump level
/// - kind: One of [added, changed, fixed] indicating the type of change
/// - description: A detailed description of the change
///
/// Examples:
/// ```
/// patch type="fixed" "Fix audio frame generation when publishing"
/// minor type="added" "Add support for custom audio processing"
/// major type="changed" "Breaking: Rename Room.connect() to Room.join()"
/// ```
///
/// The script will:
/// 1. Parse all change files in the .changes directory
/// 2. Determine the highest level change (major > minor > patch)
/// 3. Bump the version accordingly
/// 4. Generate a changelog entry
/// 5. Update version numbers in all relevant files
/// 6. Clean up the change files

enum Path {
    static let changes = ".changes"
    static let version = ".version"
    static let changelog = "CHANGELOG.md"
    static let podspec = "LiveKitClient.podspec"
    static let readme = "README.md"
    static let livekitVersion = "Sources/LiveKit/LiveKit.swift"
}

// ANSI color codes
enum Color {
    static let reset = "\u{001B}[0m"
    static let green = "\u{001B}[32m"
    static let bold = "\u{001B}[1m"
}

// Regex patterns
enum VersionPattern {
    static let podspecVersion = #"spec\.version\s*=\s*"[^"]*""#
    static let readmeVersion = #"upToNextMajor\("[^"]*""#
    static let livekitVersion = #"static let version = "[^"]*""#
}

// File operations
func readFile(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

func writeFile(_ path: String, content: String) throws {
    try content.write(toFile: path, atomically: true, encoding: .utf8)
}

struct SemanticVersion: CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(string: String) {
        let components = string.split(separator: ".").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        major = components[0]
        minor = components[1]
        patch = components[2]
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    func bumpMajor() -> SemanticVersion {
        SemanticVersion(major: major + 1, minor: 0, patch: 0)
    }

    func bumpMinor() -> SemanticVersion {
        SemanticVersion(major: major, minor: minor + 1, patch: 0)
    }

    func bumpPatch() -> SemanticVersion {
        SemanticVersion(major: major, minor: minor, patch: patch + 1)
    }
}

struct Change {
    enum Kind: String {
        case added
        case fixed
        case changed
    }

    enum Level: String, Comparable {
        case patch
        case minor
        case major

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.priority < rhs.priority
        }

        private var priority: Int {
            switch self {
            case .patch: 0
            case .minor: 1
            case .major: 2
            }
        }
    }

    let level: Level
    let kind: Kind
    let description: String
}

func getCurrentVersion() -> SemanticVersion {
    do {
        let content = try readFile(Path.version)
        let versionString = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = SemanticVersion(string: versionString) else {
            fatalError("Invalid version format in \(Path.version): \(versionString)")
        }
        return version
    } catch {
        fatalError("Failed to read \(Path.version): \(error)")
    }
}

// swiftlint:disable:next cyclomatic_complexity
func parseChanges() -> [Change] {
    let fileManager = FileManager.default

    guard let files = try? fileManager.contentsOfDirectory(atPath: Path.changes) else {
        return []
    }

    var changes: [Change] = []

    for file in files {
        let filePath = (Path.changes as NSString).appendingPathComponent(file)
        guard let content = try? readFile(filePath) else { continue }

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            // Skip empty lines
            guard !line.isEmpty else { continue }

            // Parse format: level type="kind" "description"
            let components = line.components(separatedBy: .whitespaces)
            guard components.count >= 3 else { continue }

            // Extract level
            guard let level = Change.Level(rawValue: components[0]) else { continue }

            // Extract type from type="kind" format
            let typeComponent = components[1]
            guard typeComponent.hasPrefix("type="),
                  let typeStart = typeComponent.firstIndex(of: "\""),
                  let typeEnd = typeComponent.lastIndex(of: "\""),
                  typeStart < typeEnd else { continue }

            let typeString = String(typeComponent[typeComponent.index(after: typeStart) ..< typeEnd])
            guard let kind = Change.Kind(rawValue: typeString) else { continue }

            // Extract description from the last quoted string
            if let lastQuoteStart = line.lastIndex(of: "\""),
               let lastQuoteEnd = line[..<lastQuoteStart].lastIndex(of: "\"")
            {
                let description = String(line[line.index(after: lastQuoteEnd) ..< lastQuoteStart])
                guard !description.isEmpty else { continue }
                changes.append(Change(level: level, kind: kind, description: description))
            }
        }
    }

    guard !changes.isEmpty else {
        fatalError("No changes found in \(Path.changes)")
    }

    return changes
}

func calculateNewVersion(currentVersion: SemanticVersion, changes: [Change]) -> SemanticVersion {
    let highestLevel = changes.map(\.level).max() ?? .patch

    switch highestLevel {
    case .major: return currentVersion.bumpMajor()
    case .minor: return currentVersion.bumpMinor()
    case .patch: return currentVersion.bumpPatch()
    }
}

func generateChangelogEntry(version: SemanticVersion, changes: [Change]) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    let today = dateFormatter.string(from: Date())

    var entry = "## [\(version)] - \(today)\n\n"

    // Group changes by kind
    let added = changes.filter { $0.kind == .added }
    let changed = changes.filter { $0.kind == .changed }
    let fixed = changes.filter { $0.kind == .fixed }

    if !added.isEmpty {
        entry += "### Added\n\n"
        for change in added {
            entry += "- \(change.description)\n"
        }
        entry += "\n"
    }

    if !changed.isEmpty {
        entry += "### Changed\n\n"
        for change in changed {
            entry += "- \(change.description)\n"
        }
        entry += "\n"
    }

    if !fixed.isEmpty {
        entry += "### Fixed\n\n"
        for change in fixed {
            entry += "- \(change.description)\n"
        }
        entry += "\n"
    }

    return entry
}

func appendToChangelog(entry: String) {
    do {
        let content = try readFile(Path.changelog)

        // Find the position after the header
        guard let headerRange = content.range(of: "# Changelog\n\n") else {
            fatalError("Could not find Changelog header")
        }

        // Create new content with the entry inserted after the header
        let newContent = String(content[..<headerRange.upperBound]) + entry + String(content[headerRange.upperBound...])

        try writeFile(Path.changelog, content: newContent)
    } catch {
        fatalError("Failed to update \(Path.changelog): \(error)")
    }
}

func replaceVersionInFile(_ filePath: String, pattern: String, replacement: String) {
    do {
        let content = try readFile(filePath)
        let regex = try Regex(pattern)
        let newContent = content.replacing(regex, with: replacement)
        try writeFile(filePath, content: newContent)
    } catch {
        fatalError("Failed to update \(filePath): \(error)")
    }
}

func updateVersionFiles(version: SemanticVersion) {
    do {
        try writeFile(Path.version, content: version.description)

        replaceVersionInFile(
            Path.podspec,
            pattern: VersionPattern.podspecVersion,
            replacement: "spec.version = \"\(version)\""
        )

        replaceVersionInFile(
            Path.readme,
            pattern: VersionPattern.readmeVersion,
            replacement: "upToNextMajor(\"\(version)\""
        )

        replaceVersionInFile(
            Path.livekitVersion,
            pattern: VersionPattern.livekitVersion,
            replacement: "static let version = \"\(version)\""
        )
    } catch {
        fatalError("Failed to update version files: \(error)")
    }
}

func cleanupChangesDirectory() {
    let fileManager = FileManager.default

    guard let files = try? fileManager.contentsOfDirectory(atPath: Path.changes) else {
        return
    }

    for file in files {
        // Skip files that start with a dot
        guard !file.hasPrefix(".") else { continue }

        let filePath = (Path.changes as NSString).appendingPathComponent(file)
        try? fileManager.removeItem(atPath: filePath)
    }
}

let currentVersion = getCurrentVersion()
let changes = parseChanges()
let newVersion = calculateNewVersion(currentVersion: currentVersion, changes: changes)

print("Current version: \(currentVersion)")
print("Changes detected:")
for change in changes {
    print("- [\(change.kind.rawValue)] \(change.description)")
}

print("New version: \(Color.bold)\(Color.green)\(newVersion)\(Color.reset) 🎉")

let changelogEntry = generateChangelogEntry(version: newVersion, changes: changes)
appendToChangelog(entry: changelogEntry)
print("Changelog entry added 📝")
updateVersionFiles(version: newVersion)
print("Version files updated 📦")
cleanupChangesDirectory()
print("Changes directory cleaned up 🧹")
