import SwiftUI

// Shared building blocks for the tool panels: clickable presets, an info popover that explains every control,
// and a small "what was optimised" chart (before → after) that each tool shows.

struct PresetChoice: Identifiable, Hashable {
    var id: String
    var title: String
    var icon: String
    /// one line under the title: what it is good for and roughly how long it takes
    var note: String
}

/// Two-column grid of preset tiles; the active preset is highlighted. Changing a control by hand clears the highlight.
struct PresetGrid: View {
    var presets: [PresetChoice]
    var selected: String?
    var choose: (PresetChoice) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(presets) { preset in
                let active = preset.id == selected
                Button { choose(preset) } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: preset.icon).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(active ? Color.accentColor : .secondary).frame(width: 16).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(preset.note).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                    .background(active ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? Color.accentColor.opacity(0.55) : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(preset.note)
            }
        }
    }
}

/// One explained control in an info popover.
struct ControlInfo: Identifiable {
    var name: String
    /// what the control does, in one or two sentences
    var what: String
    /// what is best for which purpose
    var best: String
    var id: String { name }
}

/// ⓘ button that opens a scrolling explanation of every control.
struct InfoButton: View {
    var title: String
    var intro: String? = nil
    var items: [ControlInfo]
    var tips: [String] = []
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .help("Was die Regler machen")
            .popover(isPresented: $shown, arrowEdge: .trailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(title).font(.headline)
                        if let intro { Text(intro).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.system(size: 12.5, weight: .semibold))
                                Text(item.what).font(.callout).fixedSize(horizontal: false, vertical: true)
                                Label { Text(item.best).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "checkmark.seal") }
                                    .font(.callout).foregroundStyle(Color.accentColor)
                            }
                            Divider()
                        }
                        if !tips.isEmpty {
                            Text("Tipps").font(.system(size: 12.5, weight: .semibold))
                            ForEach(tips, id: \.self) { tip in
                                Label { Text(tip).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "lightbulb") }.font(.callout)
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(width: 380, height: 520)
            }
    }
}

/// A measured improvement: label, value before and after, unit; `lowerIsBetter` for times.
struct Improvement: Identifiable {
    var label: String
    var before: Double
    var after: Double
    var unit: String
    var lowerIsBetter = true
    var note: String? = nil
    var id: String { label }
}

/// Small before/after bar chart: grey = standard setup, accent = how StudioPortal runs it on the MI50.
struct ImprovementChart: View {
    var title: String
    var items: [Improvement]
    var footnote: String? = nil

    private func format(_ value: Double, _ unit: String) -> String {
        let number = value >= 100 || value == value.rounded() ? String(Int(value.rounded())) : String(format: "%.1f", value)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(Color.accentColor)
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            ForEach(items) { item in
                let top = max(item.before, item.after, 0.0001)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.label).font(.system(size: 11.5, weight: .medium))
                        Spacer()
                        let factor = item.lowerIsBetter ? item.before / max(item.after, 0.0001) : item.after / max(item.before, 0.0001)
                        if min(item.before, item.after) == 0 {
                            Text(item.lowerIsBetter ? "entfällt" : "neu").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.green)
                        } else if factor >= 1.05 {
                            Text(factor >= 10 ? "\(Int(factor.rounded()))× besser" : String(format: "%.1f× besser", factor))
                                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.green)
                        }
                    }
                    bar(value: item.before, top: top, color: Color.secondary.opacity(0.35), text: "vorher " + format(item.before, item.unit))
                    bar(value: item.after, top: top, color: Color.accentColor.opacity(0.8), text: "jetzt " + format(item.after, item.unit))
                    if let note = item.note { Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            if let footnote { Text(footnote).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(11)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    private func bar(value: Double, top: Double, color: Color, text: String) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: max(4, proxy.size.width * 0.62 * value / top))
                Text(text).font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .padding(.leading, max(4, proxy.size.width * 0.62 * value / top) + 5)
            }
        }
        .frame(height: 13)
    }
}
