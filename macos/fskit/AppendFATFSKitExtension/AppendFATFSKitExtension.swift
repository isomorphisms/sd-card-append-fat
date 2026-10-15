import FSKit
import Foundation

@main
struct AppendFATFSKitExtension: UnaryFileSystemExtension {
    // One instance owns the loaded resource and its security scope.
    private static let shared = AppendFATFileSystem()
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        Self.shared
    }
}
