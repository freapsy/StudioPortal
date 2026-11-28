import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

/// Downsampled thumbnails; full-size PNGs from the generator are several MB each.
enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func image(_ url: URL, size: CGFloat) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let key = "\(url.path)#\(Int(size))#\(modified)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: Int(size * 2)] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let result = NSImage(cgImage: image, size: .zero)
        cache.setObject(result, forKey: key)
        recent.setObject(result, forKey: "\(url.path)#\(Int(size))" as NSString)
        return result
    }

    /// last decoded thumbnail without touching the disk (no stat) – for drawing right away while the real check runs
    private static let recent = NSCache<NSString, NSImage>()
    static func quick(_ url: URL, size: CGFloat) -> NSImage? { recent.object(forKey: "\(url.path)#\(Int(size))" as NSString) }
}

/// Thumbnail decoded off the main thread; shows the cached picture immediately, so scrolling and tab switches don't stall.
struct AsyncThumbnail<Placeholder: View>: View {
    var url: URL
    var size: CGFloat
    var fill = true
    @ViewBuilder var placeholder: Placeholder
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let shown = image ?? ThumbnailCache.quick(url, size: size) {
                Image(nsImage: shown).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else { placeholder }
        }
        .task(id: url) {
            let u = url, s = size
            let loaded = await Task.detached(priority: .userInitiated) { ThumbnailCache.image(u, size: s) }.value
            if let loaded { image = loaded }
        }
    }
}

// Shared building blocks so every tool has the same anatomy:
// a 320 pt control panel (header, small-caps sections, pinned primary action) and a workspace on the right.

enum Metrics {
    static let panelWidth: CGFloat = 320
    static let radius: CGFloat = 10
}

struct ToolPanel<Content: View, Footer: View>: View {
    var title: String
    var subtitle: String
    var icon: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 11) {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.7)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.headline)
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    content
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
                .padding(14)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
        }
        .frame(width: Metrics.panelWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct PanelSection<Content: View, Accessory: View>: View {
    var title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                accessory.font(.caption).foregroundStyle(.secondary)
            }
            content
        }
    }
}

extension PanelSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// A row of selectable capsules; replaces pop-up menus for short option lists.
struct ChipPicker<Value: Hashable>: View {
    var options: [(String, Value)]
    @Binding var selection: Value
    var columns: Int? = nil

    var body: some View {
        let grid = Array(repeating: GridItem(.flexible(), spacing: 6), count: columns ?? options.count)
        LazyVGrid(columns: grid, spacing: 6) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button(option.0) { selection = option.1 }
                    .buttonStyle(ChipStyle(selected: selection == option.1))
            }
        }
    }
}

struct ChipStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Full-width primary action with its keyboard shortcut shown, pinned to the bottom of every panel.
struct PrimaryActionButton: View {
    var title: String
    var icon: String
    var running: Bool
    var enabled: Bool
    var action: () -> Void
    var cancel: () -> Void

    var body: some View {
        Button { running ? cancel() : action() } label: {
            HStack(spacing: 8) {
                if running { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: icon) }
                Text(running ? "Abbrechen" : title).fontWeight(.semibold)
                Spacer(minLength: 0)
                if !running { Text("⌘↩").font(.caption.monospaced()).opacity(0.75) }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(.white)
            .background(running ? Color.red.opacity(0.85) : (enabled ? Color.accentColor : Color.secondary.opacity(0.45)), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(!running && !enabled)
        .keyboardShortcut(.return, modifiers: .command)
    }
}

/// Square drop target with thumbnail, used for 3D views and reference images.
struct DropTile: View {
    var label: String
    var url: URL?
    var size: CGFloat
    var disabled = false
    var choose: () -> Void
    var drop: (URL) -> Void
    var remove: (() -> Void)?
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Button(action: choose) {
                    ZStack {
                        if let url, let image = ThumbnailCache.image(url, size: size) {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            VStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                                Text("Bild").font(.caption2)
                            }.foregroundStyle(targeted ? Color.accentColor : .secondary)
                        }
                    }
                    .frame(width: size, height: size)
                    .background(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(url == nil ? 0.35 : 0.15),
                                          style: StrokeStyle(lineWidth: 1, dash: url == nil ? [4] : []))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    guard !disabled, let provider = providers.first else { return false }
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        if let url, url.isFileURL { DispatchQueue.main.async { drop(url) } }
                    }
                    return true
                }
                if url != nil, let remove, !disabled {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                    }.buttonStyle(.plain).padding(4).help("Entfernen")
                }
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct EmptyStateView: View {
    var icon: String
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

func elapsedText(_ seconds: TimeInterval) -> String {
    let n = max(0, Int(seconds)); return String(format: "%02d:%02d", n / 60, n % 60)
}

func thumbnail(_ url: URL, size: CGFloat) -> some View {
    Group {
        AsyncThumbnail(url: url, size: size) { Image(systemName: "photo").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }.frame(width: size, height: size).background(Color.secondary.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 7))
}
