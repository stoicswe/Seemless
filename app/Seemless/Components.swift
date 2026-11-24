import SeemlessKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - State presentation

extension VMProcess.State {
    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .paused: return "Paused"
        case .stopping: return "Shutting Down"
        case .crashed: return "Stopped Unexpectedly"
        }
    }

    var tint: Color {
        switch self {
        case .stopped: return .secondary
        case .starting, .stopping: return .orange
        case .running: return .green
        case .paused: return .yellow
        case .crashed: return .red
        }
    }

    var symbol: String {
        switch self {
        case .stopped: return "power"
        case .starting: return "arrow.up.circle"
        case .running: return "play.fill"
        case .paused: return "pause.fill"
        case .stopping: return "arrow.down.circle"
        case .crashed: return "exclamationmark.triangle.fill"
        }
    }

    var crashReason: String? {
        if case .crashed(let why) = self { return why }
        return nil
    }
}

/// Small glass capsule with a coloured dot and the state name.
struct StatusBadge: View {
    var state: VMProcess.State

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.tint)
                .frame(width: 7, height: 7)
                .shadow(color: state.tint.opacity(0.6), radius: state == .running ? 3 : 0)
            Text(state.label)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular.tint(state.tint.opacity(0.12)), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sections

/// Shared metrics so every bento box on the page lines up the same way.
enum SectionMetrics {
    static let padding: CGFloat = 18
    static let headerHeight: CGFloat = 26
    static let spacing: CGFloat = 14
    static let cornerRadius: CGFloat = 22
}

/// A titled group on a glass surface. Used sparingly: the detail page is a
/// column of these over the window background.
struct GlassSection<Content: View, Accessory: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, symbol: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SectionMetrics.spacing) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                Spacer()
                accessory
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            // Fixed header height: a button, a menu or nothing on the right
            // must not move where the content starts.
            .frame(height: SectionMetrics.headerHeight)
            content
        }
        .padding(SectionMetrics.padding)
        // Stretch inside the glass, so boxes placed side by side (in a
        // vertically fixed HStack) end up the same height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: SectionMetrics.cornerRadius))
    }
}

/// Label on the left, value on the right; the building block of sections.
struct InfoRow<Value: View>: View {
    var label: String
    @ViewBuilder var value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            value.multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

extension InfoRow where Value == Text {
    init(_ label: String, _ value: String) {
        self.init(label) { Text(value) }
    }
}

// MARK: - ISO drop zone

extension UTType {
    static let iso = UTType(filenameExtension: "iso") ?? .diskImage
}

/// Dashed glass well that accepts a dropped or chosen ISO.
struct ISODropZone: View {
    var prompt: String
    /// One line instead of a tall well (when something is already attached).
    var compact = false
    var onPick: (URL) -> Void
    @State private var targeted = false
    @State private var choosing = false

    var body: some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 10))
        layout {
            Image(systemName: "opticaldisc")
                .font(.system(size: compact ? 16 : 24, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: targeted)
            Text(prompt).font(.callout).foregroundStyle(.secondary)
            if compact { Spacer() }
            Button("Choose…") { choosing = true }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 10 : 16)
        .padding(.horizontal, compact ? 14 : 0)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
        }
        .glassEffect(.regular.tint(targeted ? .accentColor.opacity(0.15) : .clear), in: .rect(cornerRadius: 18))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.isFileURL }) else { return false }
            onPick(url)
            return true
        } isTargeted: { targeted = $0 }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.iso, .diskImage]) { result in
            if case .success(let url) = result { onPick(url) }
        }
    }
}

// MARK: - Formatting

enum Format {
    static func memory(_ mib: Int) -> String {
        mib % 1024 == 0 ? "\(mib / 1024) GB" : String(format: "%.1f GB", Double(mib) / 1024)
    }

    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .file)
    }

    static func network(_ n: VMConfig.NetworkMode) -> String {
        switch n {
        case .user: return "Shared (NAT)"
        case .vmnetShared: return "vmnet Shared"
        case .none: return "Off"
        }
    }

    static func graphics(_ g: VMConfig.GraphicsBackend) -> String {
        switch g {
        case .dxmt: return "DXMT (Metal)"
        case .d3dmetal: return "D3DMetal (Rosetta)"
        }
    }

    static func bootOrder(_ o: VMConfig.BootSettings.Order) -> String {
        switch o {
        case .diskFirst: return "System Disk First"
        case .removableFirst: return "Removable Media First"
        }
    }
}
