import SeemlessKit
import SwiftUI

/// Shows a screenshot just saved by `AppModel.takeScreenshot`.
struct ScreenshotView: View {
    @Environment(\.dismiss) private var dismiss
    let result: AppModel.ScreenshotResult
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "camera")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 50, height: 50)
                    .glassEffect(.regular, in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Screenshot of “\(result.vm)”").font(.title2.weight(.semibold))
                    Text("\(result.shot.width) × \(result.shot.height) · \(sourceText)")
                        .foregroundStyle(.secondary)
                }
            }

            Image(nsImage: result.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 640, maxHeight: 420)
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                .frame(maxWidth: .infinity)

            if result.shot.isLikelyBlankScreendump {
                Label {
                    Text("The screen came back black. Once Windows’ 3D graphics driver is running, only a VM started with **Start without Window** can be captured; QEMU’s own window can’t.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(result.file.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(result.file.path(percentEncoded: false))
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([result.image])
                    copied = true
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.file])
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.glass)
        }
        .padding(24)
        .frame(width: 688)
    }

    private var sourceText: String {
        switch result.shot.source {
        case .exportedMetal: "3D display"
        case .exported2D: "exported display"
        case .qmpScreendump: "QEMU screendump"
        }
    }
}
