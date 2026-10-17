import Foundation
import XCTest

/// `scripts/verify-iroh-ffi.sh` is what the VerifyIrohLib plugin runs before the
/// IrohLib target compiles (and what the build script runs on a fresh build):
/// the installed xcframework must match `third_party/iroh-ffi/IrohLib.sha256`.
final class IrohLibRecordTests: XCTestCase {
    private let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var repository: URL { package.deletingLastPathComponent().deletingLastPathComponent() }
    private var script: String { repository.appendingPathComponent("scripts/verify-iroh-ffi.sh").path }
    private var record: String { repository.appendingPathComponent("third_party/iroh-ffi/IrohLib.sha256").path }
    private var framework: URL { package.appendingPathComponent("Frameworks/IrohLib.xcframework") }
    private var buildScript: String { repository.appendingPathComponent("scripts/build-iroh-ffi.sh").path }

    func testInstalledFrameworkMatchesTheRecord() throws {
        try AgentLandIrohTests.run("/bin/sh", [script, record, framework.path], in: package)
    }

    func testChangedExtraOrMissingFilesAreRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-irohlib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("IrohLib.xcframework")
        // On APFS the copy is a clone, so this is quick for the 60 MB of libraries.
        try FileManager.default.copyItem(at: framework, to: copy)
        try AgentLandIrohTests.run("/bin/sh", [script, record, copy.path], in: directory)

        // One byte more in one slice's library.
        let library = copy.appendingPathComponent("macos-arm64/libiroh_ffi.a")
        let original = try Data(contentsOf: library)
        try (original + Data([0])).write(to: library)
        assertRefused(copy, because: "SHA-256 differs for macos-arm64/libiroh_ffi.a")
        try original.write(to: library)
        try AgentLandIrohTests.run("/bin/sh", [script, record, copy.path], in: directory)

        // A file the record does not list (another library the Info.plist could name).
        let extra = copy.appendingPathComponent("macos-arm64/libother.a")
        try Data("x".utf8).write(to: extra)
        assertRefused(copy, because: "different files")
        try FileManager.default.removeItem(at: extra)

        // A listed file missing.
        try FileManager.default.removeItem(at: copy.appendingPathComponent("ios-arm64/Headers/iroh_ffiFFI.h"))
        assertRefused(copy, because: "different files")
    }

    // The record holds for the pinned Xcode only: the libraries embed its clang's
    // version. build-iroh-ffi.sh stops before its lock and work directory, with
    // --update-record too, when the selected Xcode or its clang is another one.

    func testTheBuildStopsWithAnotherXcode() throws {
        let pin = try pinnedXcode()
        let tools = try toolDirectory()
        defer { try? FileManager.default.removeItem(at: tools) }
        try writeTool(tools, "xcodebuild", "printf 'Xcode 27.0\\nBuild version 18A100\\n'")
        try assertBuildRefused(tools, because: [
            "this build needs Xcode \(pin.version) (\(pin.build))", "is Xcode 27.0 (18A100)",
            "embed its compiler's version", "DEVELOPER_DIR", "--update-record"
        ])
    }

    func testTheBuildStopsWithoutAnXcode() throws {
        let tools = try toolDirectory()
        defer { try? FileManager.default.removeItem(at: tools) }
        try writeTool(tools, "xcodebuild", "echo 'xcode-select: error: tool requires Xcode' >&2; exit 1")
        try assertBuildRefused(tools, because: ["is not an Xcode"])
    }

    func testTheBuildStopsWhenTheXcodesClangIsAnotherOne() throws {
        let pin = try pinnedXcode()
        let tools = try toolDirectory()
        defer { try? FileManager.default.removeItem(at: tools) }
        try writeTool(tools, "xcodebuild", "printf 'Xcode \(pin.version)\\nBuild version \(pin.build)\\n'")
        try writeTool(tools, "clang", "echo 'Apple clang version 22.0.0 (clang-2200.0.1.1)'")
        try writeTool(tools, "xcrun", "echo '\(tools.appendingPathComponent("clang").path)'")
        try assertBuildRefused(tools, because: ["should compile with \(pin.clang)", "reports Apple clang version 22.0.0 (clang-2200.0.1.1)"])
    }

    func testThePinnedXcodePassesTheCheck() throws {
        let pin = try pinnedXcode()
        let selected = try AgentLandIrohTests.run("/usr/bin/xcodebuild", ["-version"], in: package)
        guard selected.contains("Build version \(pin.build)") else {
            throw XCTSkip("the selected Xcode is not \(pin.version) (\(pin.build)); this Mac cannot rebuild the recorded libraries")
        }
        let output = try AgentLandIrohTests.run("/bin/bash", [buildScript, "--check-xcode"], in: package)
        XCTAssertTrue(output.contains("Xcode: \(pin.version) (\(pin.build)), \(pin.clang)"), output)
    }

    // Paths with spaces (the pinned Xcode kept as "Xcode 26.6.app" beside a newer one, a
    // work directory) must reach the compilers as whole flags. cargo splits RUSTFLAGS at
    // every space, and cc-rs splits CFLAGS at every space unless CC_SHELL_ESCAPED_FLAGS is
    // set; then it splits them as a shell would (the shlex crate; Python's shlex here).

    func testPathsWithSpacesReachTheCompilersWhole() throws {
        let pin = try pinnedXcode()
        let root = try toolDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        let top = root.appendingPathComponent("it's a $dir")
        // The stand-in Xcode, selected by the stand-in xcode-select, xcodebuild and xcrun.
        let developer = top.appendingPathComponent("Xcode \(pin.version).app/Contents/Developer")
        let clangDirectory = developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin")
        try files.createDirectory(at: clangDirectory, withIntermediateDirectories: true)
        let clang = clangDirectory.appendingPathComponent("clang")
        try writeTool(clangDirectory, "clang", "echo '\(pin.clang)'")
        let tools = root.appendingPathComponent("bin")
        try files.createDirectory(at: tools, withIntermediateDirectories: true)
        try writeTool(tools, "xcodebuild", "printf 'Xcode \(pin.version)\\nBuild version \(pin.build)\\n'")
        try writeTool(tools, "xcode-select", "printf '%s\\n' \(shellQuoted(developer.path))")
        try writeTool(tools, "xcrun", "printf '%s\\n' \(shellQuoted(clang.path))")
        // git answers for a checkout of the pinned commit and does nothing else.
        try writeTool(tools, "git", "[ \"$1\" = -C ] && shift 2; [ \"$1\" = rev-parse ] && echo \(try pinned("upstream_commit")); exit 0")
        // The pinned Rust, whose cargo records what it was given and stops the build.
        let rustup = top.appendingPathComponent("rust up")
        let toolchain = rustup.appendingPathComponent("toolchains/pinned")
        for target in try pinned("targets").split(separator: " ") {
            try files.createDirectory(at: toolchain.appendingPathComponent("lib/rustlib/\(target)/lib"), withIntermediateDirectories: true)
        }
        let rustBin = toolchain.appendingPathComponent("bin")
        try files.createDirectory(at: rustBin, withIntermediateDirectories: true)
        try writeTool(rustBin, "rustc", "echo 'rustc \(try pinned("rust_version")) (0000000 2026-01-01)'")
        let seen = root.appendingPathComponent("seen")
        try files.createDirectory(at: seen, withIntermediateDirectories: true)
        try writeTool(rustBin, "cargo", """
            cd \(shellQuoted(seen.path)) || exit 1
            printf '%s' "$CFLAGS" > CFLAGS
            printf '%s' "${CC_SHELL_ESCAPED_FLAGS-}" > CC_SHELL_ESCAPED_FLAGS
            printf '%s' "${CARGO_ENCODED_RUSTFLAGS-}" > CARGO_ENCODED_RUSTFLAGS
            printf '%s' "${RUSTFLAGS-unset}" > RUSTFLAGS
            printf '%s' "$CC" > CC
            exit 3
            """)
        let work = top.appendingPathComponent("work dir")
        let source = work.appendingPathComponent("src")
        try files.createDirectory(at: source.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("Cargo.lock"))
        let cargoHome = top.appendingPathComponent("cargo home")

        let arguments = [
            "PATH=\(tools.path):/usr/bin:/bin", "RUSTUP_HOME=\(rustup.path)", "CARGO_HOME=\(cargoHome.path)",
            "AGENTLAND_IROH_WORK=\(work.path)", "RUSTFLAGS=--cfg stray", "/bin/bash", buildScript, "--skip-relay"
        ]
        XCTAssertThrowsError(try AgentLandIrohTests.run("/usr/bin/env", arguments, in: package)) { error in
            XCTAssertTrue("\(error)".contains("Building aarch64-apple-ios"), "\(error)")
        }
        func recorded(_ name: String) throws -> String {
            try String(contentsOf: seen.appendingPathComponent(name), encoding: .utf8)
        }

        // The Xcode's path resolved, as clang names its own headers (/var is /private/var).
        let resolved = try AgentLandIrohTests.run("/bin/pwd", ["-P"], in: developer).trimmingCharacters(in: .newlines)
        XCTAssertEqual(try recorded("CC"), clang.path)
        XCTAssertEqual(try recorded("CC_SHELL_ESCAPED_FLAGS"), "1")
        let cflags = try AgentLandIrohTests.run("/usr/bin/python3", [
            "-c", "import json, shlex, sys; print(json.dumps(shlex.split(open(sys.argv[1]).read())))",
            seen.appendingPathComponent("CFLAGS").path
        ], in: root)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(cflags.utf8)), [
            "-ffile-prefix-map=\(cargoHome.path)/registry=/cargo/registry",
            "-ffile-prefix-map=\(cargoHome.path)/git=/cargo/git",
            "-ffile-prefix-map=\(source.path)=/build",
            "-ffile-prefix-map=\(developer.path)=/xcode",
            "-ffile-prefix-map=\(resolved)=/xcode",
        ])
        XCTAssertEqual(try recorded("RUSTFLAGS"), "unset")
        XCTAssertEqual(try recorded("CARGO_ENCODED_RUSTFLAGS").split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init), [
            "--remap-path-prefix=\(cargoHome.path)/registry=/cargo/registry",
            "--remap-path-prefix=\(cargoHome.path)/git=/cargo/git",
            "--remap-path-prefix=\(rustup.path)=/rustup",
            "--remap-path-prefix=\(source.path)=/build",
        ])
    }

    private func pinned(_ name: String) throws -> String {
        let script = try String(contentsOfFile: buildScript, encoding: .utf8)
        let line = try XCTUnwrap(script.split(separator: "\n").first { $0.hasPrefix("\(name)=\"") }, "no \(name) in the script")
        return String(line.dropFirst(name.count + 2).dropLast())
    }

    private func pinnedXcode() throws -> (version: String, build: String, clang: String) {
        (try pinned("xcode_version"), try pinned("xcode_build"), try pinned("xcode_clang"))
    }

    private func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func toolDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-xcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeTool(_ directory: URL, _ name: String, _ body: String) throws {
        let file = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    /// Runs the build script with `tools` first on PATH, as a plain build and with
    /// --update-record; both must stop with every one of `reasons` and leave the
    /// work directory untouched.
    private func assertBuildRefused(_ tools: URL, because reasons: [String], line: UInt = #line) throws {
        let work = tools.appendingPathComponent("work")
        for options in [[], ["--update-record"]] {
            let arguments = ["PATH=\(tools.path):/usr/bin:/bin", "AGENTLAND_IROH_WORK=\(work.path)", "/bin/bash", buildScript] + options
            XCTAssertThrowsError(try AgentLandIrohTests.run("/usr/bin/env", arguments, in: package), "\(options)", line: line) { error in
                for reason in reasons {
                    XCTAssertTrue("\(error)".contains(reason), "\(options): no '\(reason)' in \(error)", line: line)
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.path), "\(options) made the work directory", line: line)
        }
    }

    private func assertRefused(_ copy: URL, because reason: String, line: UInt = #line) {
        XCTAssertThrowsError(try AgentLandIrohTests.run("/bin/sh", [script, record, copy.path], in: copy.deletingLastPathComponent()), line: line) { error in
            XCTAssertTrue("\(error)".contains(reason), "\(error)", line: line)
        }
    }
}
