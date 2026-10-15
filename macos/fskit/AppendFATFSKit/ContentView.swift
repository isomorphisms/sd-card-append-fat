import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AppendFAT FSKit").font(.title)
            Text("This app installs a user-space filesystem extension.")
            Text("Enable it under System Settings → General → Login Items & Extensions → File System Extensions.")
            Text("The current prototype mounts one append-only file from an existing scratch arena. See macos/fskit/README.md.")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 220)
    }
}
