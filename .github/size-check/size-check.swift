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

// Run via: swiftly run +xcode swift-sh .github/size-check/size-check.swift [--baseline N]
//
// Builds an empty iOS app and a LiveKit "hello world" app (via xcodegen),
// archives both unsigned for the arm64 device slice, and reports the SDK's
// size impact (uncompressed `.app` delta = benchmark, compressed IPA = info)
// plus a frameworks-vs-compiled-Swift breakdown. A non-zero `--baseline`
// enforces a budget: the delta must stay within `baseline * (1 + tolerance%)`.

struct SizeCheck: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Measure the LiveKit SDK's iOS app-size impact.")

    @Option(help: "Directory containing project.yml and the test apps.")
    var root = ".github/size-check"

    @Option(help: "Budget for the .app delta, in MB. 0 disables the gate.")
    var baseline = 0.0

    @Option(help: "Allowed growth over the baseline, in percent.")
    var tolerance = 5.0

    /// Outcome relative to the baseline: at/under it, within tolerance, or over.
    enum BudgetStatus { case ok, warning, over }

    func run() throws {
        let project = "\(root)/SizeCheck.xcodeproj"
        let build = try Folder.temporary.createSubfolder(named: "size-check-\(UUID().uuidString)")
        defer { try? build.delete() }

        try grouped("xcodegen generate") { try shellOut(to: "xcodegen", arguments: ["generate"], at: root) }
        try archive("EmptyApp", project: project, build: build)
        try archive("LiveKitApp", project: project, build: build)

        let report = try buildReport(build: build)
        emit(report.markdown)
        FileHandle.standardError.write(Data("app_delta_bytes=\(report.appDelta)\n".utf8))
        switch report.status {
        case .ok:
            break
        case .warning:
            print("::warning::LiveKit SDK app-size delta \(mb(report.appDelta)) is above the baseline (still within the +\(Int(tolerance))% tolerance).")
        case .over:
            print("::error::LiveKit SDK app-size delta \(mb(report.appDelta)) exceeds the baseline budget — see the job summary.")
            throw ExitCode.failure
        }
    }

    // MARK: - Build steps

    private func archive(_ scheme: String, project: String, build: Folder) throws {
        try grouped("archive \(scheme)") {
            do {
                try shellOut(to: "xcodebuild", arguments: [
                    "archive",
                    "-project", project,
                    "-scheme", scheme,
                    "-configuration", "Release",
                    "-destination", "generic/platform=iOS",
                    "-archivePath", "\(build.path)\(scheme).xcarchive",
                    "-derivedDataPath", "\(build.path)dd",
                    "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=",
                ])
            } catch let error as ShellOutError {
                print(error.output)
                throw ValidationError("xcodebuild archive \(scheme) failed")
            }
        }
    }

    private func appPath(_ scheme: String, build: Folder) -> String {
        "\(build.path)\(scheme).xcarchive/Products/Applications/\(scheme).app"
    }

    /// IPA = zip of `Payload/<App>.app` (no signing/thinning needed for a size proxy).
    private func makeIPA(_ scheme: String, build: Folder) throws -> String {
        let payload = try build.createSubfolderIfNeeded(withName: "Payload")
        try payload.empty()
        try Folder(path: appPath(scheme, build: build)).copy(to: payload)
        let ipa = "\(build.path)\(scheme).ipa"
        try? FileManager.default.removeItem(atPath: ipa)
        try shellOut(to: "zip", arguments: ["-qr", "-X", ipa, "Payload"], at: build.path)
        return ipa
    }

    // MARK: - Report

    private struct Report {
        let markdown: String
        let appDelta: Int
        let status: BudgetStatus
    }

    private struct Metrics {
        let emptyApp, livekitApp, emptyIPA, livekitIPA: Int
        let appDelta, ipaDelta, exec: Int
        let frameworks: [(name: String, bytes: Int)]
        let attribution: [(label: String, bytes: Int)]
        let baselineBytes, limit: Int
        let status: BudgetStatus
    }

    private func buildReport(build: Folder) throws -> Report {
        let emptyApp = appPath("EmptyApp", build: build)
        let livekitApp = appPath("LiveKitApp", build: build)
        let emptyIPA = try makeIPA("EmptyApp", build: build)
        let livekitIPA = try makeIPA("LiveKitApp", build: build)

        let appDelta = bundleBytes(livekitApp) - bundleBytes(emptyApp)
        let baselineBytes = Int(baseline * 1_048_576)
        let limit = Int(Double(baselineBytes) * (1 + tolerance / 100))
        let metrics = Metrics(
            emptyApp: bundleBytes(emptyApp),
            livekitApp: bundleBytes(livekitApp),
            emptyIPA: fileBytes(emptyIPA),
            livekitIPA: fileBytes(livekitIPA),
            appDelta: appDelta,
            ipaDelta: fileBytes(livekitIPA) - fileBytes(emptyIPA),
            exec: fileBytes("\(livekitApp)/LiveKitApp") - fileBytes("\(emptyApp)/EmptyApp"),
            frameworks: frameworkBinaries(in: livekitApp),
            attribution: linkMapAttribution(buildPath: build.path),
            baselineBytes: baselineBytes,
            limit: limit,
            status: budgetStatus(appDelta: appDelta, baselineBytes: baselineBytes, limit: limit),
        )
        return Report(markdown: render(metrics), appDelta: appDelta, status: metrics.status)
    }

    private func budgetStatus(appDelta: Int, baselineBytes: Int, limit: Int) -> BudgetStatus {
        guard baselineBytes > 0 else { return .ok }
        if appDelta > limit { return .over }
        if appDelta > baselineBytes { return .warning }
        return .ok
    }

    private func render(_ m: Metrics) -> String {
        var md = ""
        func line(_ string: String = "") { md += string + "\n" }

        line("## 📦 LiveKit SDK — iOS app size impact")
        line()
        line("**Adds `\(mb(m.appDelta))` uncompressed / `\(mb(m.ipaDelta))` compressed** to an iOS app "
            + "(arm64 device slice, Release, unsigned).")
        line()
        line("| Metric | Empty | LiveKit | Delta (SDK cost) |")
        line("|---|--:|--:|--:|")
        line("| `.app` (uncompressed — benchmark) | \(mb(m.emptyApp)) | \(mb(m.livekitApp)) | **+\(mb(m.appDelta))** |")
        line("| IPA (zip — download, info) | \(mb(m.emptyIPA)) | \(mb(m.livekitIPA)) | +\(mb(m.ipaDelta)) |")
        line()
        line("### Where it goes")
        line()
        line("| Contributor | Size | Kind |")
        line("|---|--:|---|")
        line("| **Binary frameworks** | **\(mb(m.frameworks.reduce(0) { $0 + $1.bytes }))** | dynamic `.framework` |")
        for framework in m.frameworks {
            line("| &nbsp;&nbsp;\(framework.name) | \(mb(framework.bytes)) | prebuilt |")
        }
        line("| **Compiled Swift/ObjC** (in executable) | **\(mb(m.exec))** | statically linked |")
        for entry in m.attribution where entry.bytes >= 4096 {
            line("| &nbsp;&nbsp;\(entry.label) | \(mb(entry.bytes)) | |")
        }
        line()
        if m.baselineBytes > 0 {
            let verdict = switch m.status {
            case .ok: "✅ within baseline"
            case .warning: "⚠️ above baseline, within +\(Int(tolerance))% tolerance"
            case .over: "❌ over budget"
            }
            line("**Budget:** baseline \(mb(m.baselineBytes)) · +\(Int(tolerance))% → \(mb(m.limit)) · "
                + "measured **\(mb(m.appDelta))** — \(verdict)")
            line()
        }
        line("<sub>Benchmark = uncompressed `.app` delta. Frameworks are included whole "
            + "(not dead-stripped); compiled Swift scales with usage. Generated by `.github/size-check`.</sub>")
        return md
    }

    // MARK: - Measurement helpers

    private func fileBytes(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
    }

    private func bundleBytes(_ path: String) -> Int {
        guard let folder = try? Folder(path: path) else { return 0 }
        return folder.files.recursive.reduce(0) { $0 + fileBytes($1.path) }
    }

    private func frameworkBinaries(in app: String) -> [(name: String, bytes: Int)] {
        guard let frameworks = try? Folder(path: app).subfolder(named: "Frameworks") else { return [] }
        return frameworks.subfolders
            .filter { $0.name.hasSuffix(".framework") }
            .compactMap { sub -> (String, Int)? in
                let name = String(sub.name.dropLast(".framework".count))
                guard let binary = try? sub.file(named: name) else { return nil }
                return (name, fileBytes(binary.path))
            }
            .sorted { $0.1 > $1.1 }
    }

    private func library(forObjectPath path: String) -> String {
        let buckets: [(suffix: String, label: String)] = [
            ("/App.o", "App (hello-world)"),
            ("/LiveKit.o", "LiveKit (SDK Swift)"),
            ("/SwiftProtobuf.o", "SwiftProtobuf"),
            ("/LiveKitUniFFI.o", "LiveKitUniFFI bindings"),
            ("/LKObjCHelpers.o", "LKObjCHelpers"),
        ]
        for bucket in buckets where path.hasSuffix(bucket.suffix) {
            return bucket.label
        }
        if path == "linker synthesized" { return "Swift metadata (linker)" }
        return "other (runtime/shims)"
    }

    /// Sum live-symbol bytes per object file from the `ld -map`, bucketed by library.
    private func linkMapAttribution(buildPath: String) -> [(label: String, bytes: Int)] {
        guard let dd = try? Folder(path: "\(buildPath)dd"),
              let map = dd.files.recursive.first(where: { $0.name == "LiveKitApp-LinkMap.txt" }),
              let content = try? map.readAsString()
        else { return [] }

        var files: [Int: String] = [:]
        var sizes: [Int: Int] = [:]
        var section = ""
        for line in content.components(separatedBy: .newlines) {
            if let header = mapSection(of: line) {
                section = header
            } else if section == "objects" {
                parseObjectLine(line, into: &files)
            } else if section == "symbols" {
                parseSymbolLine(line, into: &sizes)
            }
        }
        var aggregate: [String: Int] = [:]
        for (idx, size) in sizes {
            aggregate[library(forObjectPath: files[idx] ?? "?"), default: 0] += size
        }
        return aggregate.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { (label: $0.key, bytes: $0.value) }
    }

    /// The section a `# ...` header line begins, or nil for a non-header line.
    private func mapSection(of line: String) -> String? {
        if line.hasPrefix("# Object files:") { return "objects" }
        if line.hasPrefix("# Symbols:") { return "symbols" }
        if line.hasPrefix("# Sections:") || line.hasPrefix("# Dead Stripped") { return "" }
        return nil
    }

    /// `[  N] /path/to/File.o`
    private func parseObjectLine(_ line: String, into files: inout [Int: String]) {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              let idx = Int(line[line.index(after: line.startIndex) ..< close].trimmingCharacters(in: .whitespaces))
        else { return }
        files[idx] = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
    }

    /// `0xADDR 0xSIZE [  N] name`
    private func parseSymbolLine(_ line: String, into sizes: inout [Int: Int]) {
        guard let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]"), open < close,
              let idx = Int(line[line.index(after: open) ..< close].trimmingCharacters(in: .whitespaces))
        else { return }
        let fields = line[..<open].split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return }
        let hex = fields[1].hasPrefix("0x") ? String(fields[1].dropFirst(2)) : String(fields[1])
        guard let size = Int(hex, radix: 16) else { return }
        sizes[idx, default: 0] += size
    }

    private func mb(_ bytes: Int) -> String { String(format: "%.2f MB", Double(bytes) / 1_048_576) }

    // MARK: - Output

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

SizeCheck.main()
