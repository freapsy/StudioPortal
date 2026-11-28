import SwiftUI

// Layout shared by Bild, Musik and Video since 17.11.2026 (Mobbin references: Artlist, OpenAI, Grok, Leonardo, Krea):
// result in the middle, a composer at the bottom (text + small option pills + action), history as a feed on the right
// with prompt, details and "reuse" buttons. Options live in popovers behind the pills instead of a long side panel.

/// Tool header: icon, title, one line of context and room for actions on the right.
struct ToolHeader<Actions: View>: View {
    var title: String
    var subtitle: String
    var icon: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.7)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 18).frame(height: 54)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A capsule that opens its options in a popover ("16:9 · 4 MP ⌄").
struct OptionPill<Content: View>: View {
    var icon: String
    var title: String
    var help: String
    var highlighted = false
    var width: CGFloat = 300
    @ViewBuilder var content: Content
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.55)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
            .background(highlighted ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(highlighted ? Color.accentColor.opacity(0.45) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $shown, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14).frame(width: width, alignment: .leading)
        }
    }
}

/// Small heading inside a pill popover.
struct PopoverTitle: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}

/// Seed controls used in every composer: number, dice, lock.
struct SeedEditor: View {
    @Binding var seed: Int64
    @Binding var locked: Bool
    var range: ClosedRange<Int64> = 0...Int64(Int32.max)
    var note: String

    var body: some View {
        PopoverTitle("Seed")
        HStack(spacing: 6) {
            TextField("Seed", value: $seed, format: .number.grouping(.never)).textFieldStyle(.roundedBorder)
            Button { seed = Int64.random(in: range) } label: { Image(systemName: "dice") }.help("Zufälliger Seed")
            Toggle(isOn: $locked) { Image(systemName: locked ? "lock.fill" : "lock.open") }
                .toggleStyle(.button).help(locked ? "Seed festgehalten" : "Bei jedem Lauf neuer Seed")
        }
        Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Bottom composer: optional extra row (references, lyrics), the main text, then pills and the action button.
struct Composer<Above: View, Pills: View>: View {
    @Binding var text: String
    var placeholder: String
    var actionTitle: String
    var actionIcon: String
    var running: Bool
    var enabled: Bool
    var action: () -> Void
    var cancel: () -> Void
    var minHeight: CGFloat = 44
    var maxHeight: CGFloat = 150
    @ViewBuilder var above: Above
    @ViewBuilder var pills: Pills

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            above
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 1).allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.body).scrollContentBackground(.hidden)
                    .frame(minHeight: minHeight, maxHeight: maxHeight)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ChipFlow(spacing: 6) { pills }
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                Button { running ? cancel() : action() } label: {
                    HStack(spacing: 6) {
                        if running { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: actionIcon) }
                        Text(running ? "Abbrechen" : actionTitle).fontWeight(.semibold)
                        if !running { Text("⌘↩").font(.caption.monospaced()).opacity(0.7) }
                    }
                    .padding(.horizontal, 14).frame(height: 32)
                    .foregroundStyle(.white)
                    .background(running ? Color.red.opacity(0.85) : (enabled ? Color.accentColor : Color.secondary.opacity(0.45)), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!running && !enabled)
                .keyboardShortcut(.return, modifiers: .command)
                .fixedSize()
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.09)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 3)
        .frame(maxWidth: 940)
        .padding(.horizontal, 18).padding(.bottom, 16).padding(.top, 8)
    }
}

/// Small grey detail chip in the feed ("4 MP", "Seed 123", "2:15").
struct MetaChip: View {
    var text: String
    var icon: String? = nil
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .medium))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        .background((tint == .secondary ? Color.secondary : tint).opacity(0.12), in: Capsule())
    }
}

/// Simple wrapping row for chips (feed cards are narrow).
struct ChipFlow: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}

/// Header of the feed column on the right.
struct FeedHeader: View {
    var title: String
    var count: Int
    var folder: URL
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button { NSWorkspace.shared.open(folder) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Ordner im Finder öffnen")
                .disabled(!FileManager.default.fileExists(atPath: folder.path))
        }
        .padding(.horizontal, 14).frame(height: 38)
        .overlay(alignment: .bottom) { Divider() }
    }
}

enum FeedMetrics { static let width: CGFloat = 300 }

/// Picture in a feed card: whole image (aspect fit), at most 220 pt high.
struct FeedImage: View {
    var url: URL
    var body: some View {
        AsyncThumbnail(url: url, size: 280, fill: false) {
            Image(systemName: "photo").foregroundStyle(.secondary).frame(height: 120)
        }
        .frame(maxWidth: .infinity, maxHeight: 220)
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Small round × that closes the result shown on the stage (back to the start view for something new).
struct StageCloseButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain).help("Schließen – zurück zu „Neu“ (Esc)").keyboardShortcut(.cancelAction)
    }
}

/// Start view of a tool when nothing is selected: short steps plus clickable starting points.
struct StartView<Extra: View>: View {
    var icon: String
    var title: String
    var steps: [String]
    @ViewBuilder var extra: Extra
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(Color.accentColor)
                Text(title).font(.title2.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 18, height: 18).background(Color.accentColor.opacity(0.8), in: Circle())
                        Text(step).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            extra
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
    }
}
