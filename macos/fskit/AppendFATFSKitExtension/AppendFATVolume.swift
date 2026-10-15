import Darwin
import Foundation
import FSKit

/// The first vertical slice deliberately exposes one append-only virtual file.
/// No overwrite, truncate, unlink, rename, or symlink operations are admitted.
final class AppendFATItem: FSItem {
    enum Kind { case root, log }
    let kind: Kind
    init(_ kind: Kind) {
        self.kind = kind
        super.init()
    }
}

final class AppendFATVolume: FSVolume {
    private let arenaPath: String
    private let root = AppendFATItem(.root)
    private let log = AppendFATItem(.log)
    private let logName = FSFileName(string: "append.log")
    private let logID = FSItem.Identifier(rawValue: 3)!
    private let createdAt: timespec

    init(arenaPath: String) {
        self.arenaPath = arenaPath
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        self.createdAt = now
        super.init(volumeID: FSVolume.Identifier(
            uuid: UUID(uuidString: "0D90DE0D-008D-47DD-A4E0-3B9FF50F374B")!),
            volumeName: FSFileName(string: "AppendFAT"))
    }

    private func status() -> (UInt64, UInt64, Int32) {
        var used: UInt64 = 0
        var capacity: UInt64 = 0
        let code = arenaPath.withCString {
            appendfat_fskit_status($0, &used, &capacity)
        }
        return (used, capacity, code)
    }

    private func error(_ code: Int32) -> POSIXError {
        POSIXError(POSIXError.Code(rawValue: code) ?? .EIO)
    }

    private func attributes(for item: AppendFATItem,
                            wanted: FSItem.GetAttributesRequest?) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        let isRoot = item.kind == .root
        let (used, capacity, _) = status()
        func wants(_ attr: FSItem.Attribute) -> Bool {
            wanted?.isAttributeWanted(attr) ?? true
        }
        if wants(.type) { attrs.type = isRoot ? .directory : .file }
        if wants(.fileID) { attrs.fileID = isRoot ? .rootDirectory : logID }
        if wants(.parentID) { attrs.parentID = isRoot ? .parentOfRoot : .rootDirectory }
        if wants(.uid) { attrs.uid = getuid() }
        if wants(.gid) { attrs.gid = getgid() }
        if wants(.mode) { attrs.mode = isRoot ? 0o755 : 0o644 }
        if wants(.linkCount) { attrs.linkCount = isRoot ? 2 : 1 }
        if wants(.flags) { attrs.flags = 0 }
        if wants(.size) { attrs.size = isRoot ? 0 : used }
        if wants(.allocSize) { attrs.allocSize = isRoot ? 0 : capacity }
        if wants(.accessTime) { attrs.accessTime = createdAt }
        if wants(.changeTime) { attrs.changeTime = createdAt }
        if wants(.modifyTime) { attrs.modifyTime = createdAt }
        if wants(.birthTime) { attrs.birthTime = createdAt }
        return attrs
    }
}

extension AppendFATVolume: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSizeInBits: Int { 63 }
    var maximumXattrSizeInBits: Int { 0 }
}

extension AppendFATVolume: FSVolume.Operations {
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities()
        c.supportsHardLinks = false
        c.supportsSymbolicLinks = false
        c.supportsPersistentObjectIDs = false
        c.supports64BitObjectIDs = true
        c.supportsFastStatFS = true
        c.caseFormat = .sensitive
        return c
    }

    var volumeStatistics: FSStatFSResult {
        let (used, capacity, _) = status()
        let r = FSStatFSResult(fileSystemTypeName: "appendfat")
        r.blockSize = 4096
        r.ioSize = 4096
        r.totalBlocks = (capacity + 4095) / 4096
        r.usedBlocks = (used + 4095) / 4096
        r.freeBlocks = (capacity - used) / 4096
        r.availableBlocks = r.freeBlocks
        r.totalFiles = 2
        r.freeFiles = 0
        return r
    }

    func activate(options: FSTaskOptions,
                  replyHandler: @escaping (FSItem?, (any Error)?) -> Void) {
        replyHandler(root, nil)
    }
    func deactivate(options: FSDeactivateOptions,
                    replyHandler: @escaping ((any Error)?) -> Void) {
        replyHandler(nil)
    }
    func mount(options: FSTaskOptions,
               replyHandler: @escaping (Error?) -> Void) {
        replyHandler(nil)
    }
    func unmount(replyHandler: @escaping () -> Void) { replyHandler() }

    // Every successful append is already synchronized by the arena core.
    func synchronize(flags: FSSyncFlags,
                     replyHandler: @escaping ((any Error)?) -> Void) {
        let (_, _, code) = status()
        replyHandler(code == 0 ? nil : error(code))
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard directory === root else {
            return replyHandler(nil, nil, POSIXError(.ENOTDIR))
        }
        guard name.string == "append.log" else {
            return replyHandler(nil, nil, POSIXError(.ENOENT))
        }
        replyHandler(log, logName, nil)
    }
    func reclaimItem(_ item: FSItem,
                     replyHandler: @escaping ((any Error)?) -> Void) { replyHandler(nil) }
    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem,
                       replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let item = item as? AppendFATItem else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        let (_, _, code) = status()
        guard code == 0 else { return replyHandler(nil, error(code)) }
        replyHandler(attributes(for: item, wanted: desiredAttributes), nil)
    }
    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
                       replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        // A timestamp update is not a request to change the durable log.
        let refused: [FSItem.Attribute] = [
            .type, .mode, .linkCount, .uid, .gid, .flags,
            .size, .allocSize, .fileID, .parentID
        ]
        if refused.contains(where: { newAttributes.isValid($0) }) {
            return replyHandler(nil, POSIXError(.EROFS))
        }
        let times: [FSItem.Attribute] = [
            .accessTime, .modifyTime, .changeTime, .birthTime, .backupTime, .addedTime
        ]
        var consumed: FSItem.Attribute = []
        for flag in times where newAttributes.isValid(flag) { consumed.insert(flag) }
        newAttributes.consumedAttributes = consumed
        replyHandler(nil, nil)
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType,
                    inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest,
                    replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, nil, POSIXError(.EROFS))
    }
    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes: FSItem.SetAttributesRequest, linkContents: FSFileName,
                            replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, nil, POSIXError(.EROFS))
    }
    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, POSIXError(.EROFS))
    }
    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
                    replyHandler: @escaping ((any Error)?) -> Void) {
        replyHandler(POSIXError(.EROFS))
    }
    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, POSIXError(.EROFS))
    }
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker,
                            replyHandler: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        guard directory === root else {
            return replyHandler(FSDirectoryVerifier(0), POSIXError(.ENOTDIR))
        }
        if cookie.rawValue == 0 {
            let (_, _, code) = status()
            guard code == 0 else {
                return replyHandler(FSDirectoryVerifier(0), error(code))
            }
            _ = packer.packEntry(name: logName, itemType: .file, itemID: logID,
                                 nextCookie: FSDirectoryCookie(1),
                                 attributes: attributes.map { self.attributes(for: log, wanted: $0) })
        }
        replyHandler(FSDirectoryVerifier(0), nil)
    }
    func readSymbolicLink(_ item: FSItem,
                          replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, POSIXError(.EINVAL))
    }
}

extension AppendFATVolume: FSVolume.ReadWriteOperations {
    func read(from item: FSItem, at offset: off_t, length: Int,
              into buffer: FSMutableFileDataBuffer,
              replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard item === log, offset >= 0, length >= 0 else {
            return replyHandler(0, POSIXError(.EINVAL))
        }
        var got = 0
        var code: Int32 = 0
        buffer.withUnsafeMutableBytes { dst in
            let size = min(length, dst.count)
            var readCount: Int = 0
            code = arenaPath.withCString {
                appendfat_fskit_read($0, UInt64(offset), dst.baseAddress, size, &readCount)
            }
            got = readCount
        }
        replyHandler(code == 0 ? got : 0, code == 0 ? nil : error(code))
    }

    func write(contents: Data, to item: FSItem, at offset: off_t,
               replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard item === log, offset >= 0 else {
            return replyHandler(0, POSIXError(.EINVAL))
        }
        var newCommitted: UInt64 = 0
        let code = contents.withUnsafeBytes { src in
            arenaPath.withCString {
                appendfat_fskit_append($0, UInt64(offset),
                                      src.baseAddress, src.count, &newCommitted)
            }
        }
        replyHandler(code == 0 ? contents.count : 0,
                     code == 0 ? nil : error(code))
    }
}
