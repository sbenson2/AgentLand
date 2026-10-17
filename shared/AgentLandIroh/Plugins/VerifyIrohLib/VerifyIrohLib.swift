import Foundation
import PackagePlugin

/// Checks `Frameworks/IrohLib.xcframework` against the committed SHA-256 record
/// (`third_party/iroh-ffi/IrohLib.sha256`) with `scripts/verify-iroh-ffi.sh`
/// before the IrohLib target compiles, so nothing links a library the record does
/// not list: a stale build from before a patch changed, another checkout's build,
/// or a replaced file. SwiftPM and Xcode run the check again whenever the record,
/// the script or a file in the framework changes; a mismatch fails the build.
///
/// (A check in Package.swift would not do: SwiftPM caches the evaluated manifest
/// and does not evaluate it again when the library changes.)
@main
struct VerifyIrohLib: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let package = context.package.directoryURL
        let repository = package.deletingLastPathComponent().deletingLastPathComponent()
        let script = repository.appending(path: "scripts/verify-iroh-ffi.sh")
        let record = repository.appending(path: "third_party/iroh-ffi/IrohLib.sha256")
        let framework = package.appending(path: "Frameworks/IrohLib.xcframework")
        let stamp = context.pluginWorkDirectoryURL.appending(path: "IrohLibVerified.swift")
        let files = (FileManager.default.enumerator(at: framework, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }) ?? []
        return [
            .buildCommand(
                displayName: "Checking IrohLib.xcframework against third_party/iroh-ffi/IrohLib.sha256",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path, record.path, framework.path, stamp.path],
                inputFiles: [script, record] + files,
                outputFiles: [stamp]
            )
        ]
    }
}
