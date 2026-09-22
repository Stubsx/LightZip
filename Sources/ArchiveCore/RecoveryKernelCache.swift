import Foundation
import CryptoKit
import Darwin

/// Bundled kernel sources and compiled GPU programs may persist. Archive hashes,
/// candidates, results and sessions stay inside the disposable job directory.
struct RecoveryKernelCache {
    let directory: URL
    private let fm = FileManager.default

    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.lightzip.app/RecoveryKernels", isDirectory: true)
    }

    init?(toolsDirectory: URL, root: URL) {
        let manifest = toolsDirectory.appendingPathComponent("hashcat/cache-version")
        guard let version = try? String(contentsOf: manifest, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              version.count == 64, version.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        // Hashcat's filenames additionally include device, driver and kernel
        // options. This namespace also changes on runtime or macOS updates.
        let identity = version + "|" + ProcessInfo.processInfo.operatingSystemVersionString
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = root.appendingPathComponent(key, isDirectory: true)
    }

    func prepareSources(from source: URL) throws -> URL {
        // Apple recompiles some cached OpenCL binaries when their include path
        // changes. Keep that path stable, and ASCII even for a Chinese username.
        let base = directory.path.utf8.allSatisfy({ $0 < 128 }) ? directory :
            fm.temporaryDirectory.appendingPathComponent("lightzip-gpu-sources-" + directory.lastPathComponent)
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = base.appendingPathComponent("OpenCL", isDirectory: true)
        if fm.fileExists(atPath: target.path) { return target }
        let temporary = base.appendingPathComponent(".sources-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        do { try fm.moveItem(at: temporary, to: target) }
        catch { if !fm.fileExists(atPath: target.path) { throw error } }
        return target
    }

    @discardableResult func restore(to stage: URL) throws -> Int {
        guard fm.fileExists(atPath: directory.path) else { return 0 }
        let target = stage.appendingPathComponent("kernels", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var count = 0
        for file in try kernelFiles(in: directory) {
            let destination = target.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: destination.path) {
                try fm.copyItem(at: file, to: destination)
                count += 1
            }
        }
        return count
    }

    func save(from stage: URL) throws {
        let source = stage.appendingPathComponent("kernels", isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { return }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for file in try kernelFiles(in: source) {
            let destination = directory.appendingPathComponent(file.lastPathComponent)
            let temporary = directory.appendingPathComponent("." + UUID().uuidString)
            defer { try? fm.removeItem(at: temporary) }
            try fm.copyItem(at: file, to: temporary)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            // Publish whole files atomically; overlapping jobs never read a
            // half-written compiler output.
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    func invalidate() {
        // Active jobs link to the stable sources, so invalidate only binaries.
        for file in (try? kernelFiles(in: directory)) ?? [] { try? fm.removeItem(at: file) }
    }

    private func kernelFiles(in folder: URL) throws -> [URL] {
        var result: [URL] = [], bytes = 0
        for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard ["kernel", "metallib"].contains(file.pathExtension),
                  let attributes = try? fm.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? Int, size > 0, size <= 64 * 1024 * 1024 else { continue }
            guard result.count < 512, bytes + size <= 256 * 1024 * 1024 else { break }
            bytes += size
            result.append(file)
        }
        return result
    }
}
