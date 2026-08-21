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
import ShellOut // JohnSundell/ShellOut ~> 2.3

// Run via: swiftly run +xcode swift-sh .github/api-check/api-check.swift --base <ref> [--platform P]
//
// Builds LiveKit for distribution (library evolution) at HEAD and at a base ref,
// dumps each module's API surface with `swift-api-digester -dump-sdk`, and
// diagnoses the delta both ways round. Breaking changes fail the job; additions
// are reported alongside them for review. An intended break is acknowledged by
// moving the base (i.e. merging it), not by allowlisting it here.

struct APICheck: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Detect public API breakage against a base ref.")

    @Option(help: "Platform to build for, e.g. macOS or iOS. Must not contain spaces.")
    var platform = "macOS"

    @Option(help: "Git ref to compare against: a branch, tag, or SHA.")
    var base: String

    func run() throws {
        let work = try Folder.temporary.createSubfolder(named: "api-check-\(UUID().uuidString)")
        let head = try Folder(path: shellOut(to: "git", arguments: ["rev-parse", "--show-toplevel"]))
        let baseTree = "\(work.path)base"
        defer {
            try? shellOut(to: "git", arguments: ["worktree", "remove", "--force", baseTree], at: head.path)
            try? work.delete()
        }

        let baseRef = try resolve(base, at: head.path)
        try grouped("checkout \(baseRef)") {
            try shellOut(to: "git", arguments: ["worktree", "add", "--detach", baseTree, baseRef], at: head.path)
        }
        let old = try dump(source: baseTree, into: work, named: "base")
        let new = try dump(source: head.path, into: work, named: "head")

        let breaking = try diagnose(old: old, new: new, into: work, named: "breaking")
        let additions = try additions(old: old, new: new, into: work)
        guard !breaking.isEmpty || !additions.isEmpty else {
            print("No public API changes on \(platform).")
            return
        }
        emit(render(breaking: breaking, additions: additions))
        guard breaking.isEmpty else {
            print("::error::Public API breakage on \(platform) — see the job summary.")
            throw ExitCode.failure
        }
    }

    /// A checkout leaves only the checked-out branch as a local ref; every other
    /// branch arrives as `origin/<name>`, and `--detach` disables the DWIM that
    /// would otherwise resolve the bare name. Tags and SHAs resolve as given.
    private func resolve(_ ref: String, at repo: String) throws -> String {
        // ShellOut joins arguments into one shell command without quoting them, so
        // the ref has to be inert before it reaches git — otherwise a `;` both runs
        // as a command and makes the check below succeed on a ref that not exist.
        // Nothing valid is excluded: git rejects refs containing space, `~`, `^`,
        // `:`, `?`, `*`, `[` or `\`.
        let allowed = { (c: Character) in c.isLetter || c.isNumber || "._/@-".contains(c) }
        guard !ref.isEmpty, ref.allSatisfy(allowed) else {
            throw ValidationError("base ref '\(ref)' is not a valid git ref")
        }
        for candidate in [ref, "origin/\(ref)"] {
            let sha = try? shellOut(to: "git", arguments: ["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"], at: repo)
            if sha != nil { return candidate }
        }
        throw ValidationError("cannot resolve base ref '\(ref)'")
    }

    // MARK: - Build & dump

    /// Builds `source` for distribution and returns the path of its API dump.
    private func dump(source: String, into work: Folder, named name: String) throws -> String {
        let derived = "\(work.path)dd-\(name)"
        try grouped("build \(name)") {
            do {
                try shellOut(to: "xcodebuild", arguments: [
                    "build", "-quiet",
                    "-scheme", "LiveKit",
                    "-configuration", "Release",
                    // Generic: no simulator device or runtime version to keep
                    // pinned, and no space to quote past ShellOut.
                    "-destination", "generic/platform=\(platform)",
                    "-derivedDataPath", derived,
                    // Both builds share one package cache: the WebRTC xcframework
                    // is ~0.5 GB and would otherwise be downloaded twice.
                    "-clonedSourcePackagesDirPath", "\(work.path)spm",
                    // One slice, so exactly one .swiftmodule to digest.
                    "ARCHS=arm64",
                    "BUILD_LIBRARY_FOR_DISTRIBUTION=YES",
                ], at: source)
            } catch let error as ShellOutError {
                print(error.output)
                print(error.message)
                throw ValidationError("xcodebuild build \(name) failed")
            }
        }

        let output = "\(work.path)\(name).json"
        try grouped("dump \(name)") {
            let build = try Folder(path: "\(derived)/Build")
            guard let products = try build.subfolder(named: "Products").subfolders
                .first(where: { $0.name.hasPrefix("Release") })
            else { throw ValidationError("no Release products in \(derived)") }
            // The .swiftmodule's basename is the triple it was built for.
            guard let triple = try products.subfolder(named: "LiveKit.swiftmodule").files
                .first(where: { $0.extension == "swiftmodule" })?.nameExcludingExtension
            else { throw ValidationError("no swiftmodule in \(products.path)") }
            // `Release-iphoneos` -> `iphoneos`; plain `Release` -> macOS.
            let suffix = products.name.dropFirst("Release".count).drop { $0 == "-" }
            let sdk = try shellOut(to: "xcrun", arguments: [
                "--sdk", suffix.isEmpty ? "macosx" : String(suffix), "--show-sdk-path",
            ])

            try shellOut(to: "xcrun", arguments: [
                "swift-api-digester", "-dump-sdk",
                "-module", "LiveKit",
                "-target", triple,
                "-sdk", sdk,
                "-I", products.path, "-F", products.path, "-F", "\(products.path)PackageFrameworks",
                "-abort-on-module-fail",
                "-o", output,
            ] + cModuleArguments(source: source, build: build))
            // -abort-on-module-fail still exits 0 when the module fails to load,
            // leaving an empty dump behind.
            let size = (try? FileManager.default.attributesOfItem(atPath: output))?[.size] as? Int
            guard let size, size > 0 else {
                throw ValidationError("swift-api-digester produced no dump for \(name)")
            }
        }
        return output
    }

    /// swift-api-digester can't reach `CLiveKitProto` on its own: the module lives
    /// behind the module map Xcode generates for the C target, and its headers
    /// include nanopb's `<pb.h>` by angle brackets.
    private func cModuleArguments(source: String, build: Folder) -> [String] {
        guard let intermediates = try? build.subfolder(named: "Intermediates.noindex"),
              let moduleMap = intermediates.files.recursive.first(where: { $0.name == "CLiveKitProto.modulemap" })
        else { return [] }
        return [
            "-Xcc", "-fmodule-map-file=\(moduleMap.path)",
            "-Xcc", "-I\(source)/Sources/CLiveKitProto/include",
        ]
    }

    // MARK: - Diagnose

    /// The digester only reports what a consumer would trip over, never additions.
    /// Diffing the other way round surfaces them: whatever "disappears" going from
    /// HEAD back to the base is new in HEAD.
    ///
    /// A reversed report is not purely additive, though, so it is gated twice: to
    /// the sections that can mean "present here, absent there", and then to the
    /// lines actually phrased as a removal. The second gate matters because a
    /// section like Protocol Conformance Change also files diagnostics that are
    /// themselves worded as additions (`has added inherited protocol`, `has added
    /// a conformance to an existing protocol`) yet are breaking — reversed, those
    /// are mirrors of a forward finding, and relabelling them is impossible. What
    /// cannot be inverted is dropped; the forward report already covers it.
    private func additions(old: String, new: String, into work: Folder) throws -> [String] {
        let additive = ["Removed Decls", "Protocol Conformance Change"]
        let inversions = [
            (" has been removed", " has been added"),
            (" has removed conformance to ", " has added conformance to "),
        ]
        return try diagnose(old: new, new: old, into: work, named: "additions")
            .filter { additive.contains($0.section) }
            .flatMap(\.lines)
            .compactMap { line in
                let inverted = inversions.reduce(line) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
                return inverted == line ? nil : inverted
            }
    }

    /// Sections of the digester report that actually contain findings.
    private func diagnose(old: String, new: String, into work: Folder,
                          named name: String) throws -> [(section: String, lines: [String])]
    {
        let report = "\(work.path)\(name).txt"
        try grouped("diagnose \(name)") {
            try shellOut(to: "xcrun", arguments: [
                "swift-api-digester", "-diagnose-sdk",
                "-input-paths", old,
                "-input-paths", new,
                "-o", report,
            ])
        }
        // The digester exits 0 whether or not it found anything; the report is the
        // verdict. Every line is a `/* Section */` header, a blank, or a finding.
        var sections: [(String, [String])] = []
        for line in try File(path: report).readAsString().components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("/*") {
                sections.append((trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/* ")), []))
            } else if !trimmed.isEmpty, !sections.isEmpty {
                sections[sections.count - 1].1.append(trimmed)
            }
        }
        return sections.filter { !$0.1.isEmpty }.map { (section: $0.0, lines: $0.1) }
    }

    // MARK: - Output

    private func render(breaking: [(section: String, lines: [String])], additions: [String]) -> String {
        var md = "## 🔒 LiveKit SDK — public API changes (`\(platform)`)\n\n"
        md += "Comparing `HEAD` against `\(base)`:\n\n"
        if !breaking.isEmpty {
            md += "### ❌ Breaking\n\n"
            for finding in breaking {
                md += "**\(finding.section)**\n\n"
                for line in finding.lines {
                    md += "- `\(line)`\n"
                }
                md += "\n"
            }
        }
        if !additions.isEmpty {
            md += "### ✅ Added\n\n"
            for line in additions {
                md += "- `\(line)`\n"
            }
            md += "\n"
        }
        md += "<sub>Breaking changes fail the job: they are source- or ABI-breaking for existing "
        md += "consumers, so bump accordingly if intended. Additions are reported for review only, "
        md += "and a mid-enum `@objc` case is not among them — the digester does not see the raw "
        md += "values it shifts. Generated by `.github/api-check`.</sub>\n"
        return md
    }

    private func grouped(_ title: String, _ body: () throws -> Void) throws {
        print("::group::\(title)")
        defer { print("::endgroup::") }
        try body()
    }

    private func emit(_ markdown: String) {
        print(markdown, terminator: "")
        if let summary = ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"] {
            try? File(path: summary).append(markdown)
        }
    }
}

APICheck.main()
