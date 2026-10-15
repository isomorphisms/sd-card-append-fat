import Darwin
import Foundation
import FSKit

/// Path-backed FSKit resource. The path is an explicit scratch directory
/// containing an EXISTING append.arena and its .used/.lock sidecars.
/// Never mount the host's root directory or create backing files at mount.
final class AppendFATFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    private static let containerUUID = UUID(uuidString: "E5358821-2897-4AC4-A740-8A25542CE8FA")!
    private let stateLock = NSLock()
    private var volume: AppendFATVolume?
    private var scopedURL: URL?

    func probeResource(resource: FSResource,
                       replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let path = resource as? FSPathURLResource, path.url.isFileURL else {
            return replyHandler(.notRecognized, nil)
        }
        replyHandler(.usable(name: "AppendFAT",
                             containerID: FSContainerIdentifier(uuid: Self.containerUUID)), nil)
    }

    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let path = resource as? FSPathURLResource, path.url.isFileURL,
              path.url.path.hasPrefix("/"), path.isWritable else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        if options.taskOptions.contains(where: { $0 == "-f" || $0.hasPrefix("-f ") }) {
            return replyHandler(nil, POSIXError(.ENOTSUP))
        }

        stateLock.lock()
        defer { stateLock.unlock() }
        guard volume == nil else { return replyHandler(nil, POSIXError(.EBUSY)) }

        // Scope is held until unload; FSKit's sandbox cannot inspect an
        // arbitrary path unless the security-scoped resource grants access.
        let didStartScope = path.url.startAccessingSecurityScopedResource()
        let arenaURL = path.url.appendingPathComponent("append.arena", isDirectory: false)
        var committed: UInt64 = 0
        var capacity: UInt64 = 0
        let result = arenaURL.path.withCString {
            appendfat_fskit_status($0, &committed, &capacity)
        }
        guard result == 0 else {
            if didStartScope { path.url.stopAccessingSecurityScopedResource() }
            return replyHandler(nil, Self.posix(result))
        }
        guard capacity > 0, committed <= capacity else {
            if didStartScope { path.url.stopAccessingSecurityScopedResource() }
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        let loaded = AppendFATVolume(arenaPath: arenaURL.path)
        volume = loaded
        scopedURL = didStartScope ? path.url : nil
        containerStatus = .ready
        replyHandler(loaded, nil)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler: @escaping ((any Error)?) -> Void) {
        stateLock.lock()
        let previousScope = scopedURL
        scopedURL = nil
        volume = nil
        stateLock.unlock()
        previousScope?.stopAccessingSecurityScopedResource()
        replyHandler(nil)
    }

    private static func posix(_ code: Int32) -> POSIXError {
        POSIXError(POSIXError.Code(rawValue: code) ?? .EIO)
    }
}
