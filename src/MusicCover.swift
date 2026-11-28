import SwiftUI

/// Cover for a song that tells songs apart at a glance – not random:
/// colour = the description (all variants and full renders of one description share it),
/// bar pattern = the melody seed (a preview and its full render look identical, variants differ),
/// icon = with or without vocals, badge = preview or full quality.
struct MusicCover: View {
    var caption: String
    var seed: Int64?
    var instrumental: Bool
    var preview: Bool
    var compact = false

    /// stable across launches (Swift's hashValue is not)
    static func stableHash(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }
    static func groupKey(_ caption: String) -> String {
        caption.replacingOccurrences(of: "No vocals. Purely instrumental.", with: "")
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }
    static func hue(_ caption: String) -> Double { Double(stableHash(groupKey(caption)) % 360) / 360 }

    private var bars: [Double] {
        var x = UInt64(bitPattern: seed ?? Int64(Self.stableHash(caption) & 0x7fffffff)) &+ 0x9e3779b97f4a7c15
        return (0..<(compact ? 9 : 16)).map { _ in
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            return 0.25 + Double(x % 1000) / 1000 * 0.75
        }
    }

    var body: some View {
        let h = Self.hue(caption)
        ZStack {
            LinearGradient(colors: [Color(hue: h, saturation: 0.55, brightness: 0.78), Color(hue: (h + 0.09).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { geo in
                let values = bars
                let gap: CGFloat = compact ? 2 : 4
                let width = (geo.size.width * 0.8 - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                        RoundedRectangle(cornerRadius: width / 2).fill(.white.opacity(0.32))
                            .frame(width: max(2, width), height: geo.size.height * 0.42 * v)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height * 0.88, alignment: .bottom)
            }
            if !compact {
                VStack {
                    HStack {
                        Spacer()
                        Text(preview ? "Vorschau" : "Voll").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background((preview ? Color.black.opacity(0.25) : Color.green.opacity(0.55)), in: Capsule())
                    }
                    Spacer()
                    HStack {
                        Image(systemName: instrumental ? "pianokeys" : "music.mic").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                            .help(instrumental ? "ohne Gesang" : "mit Gesang")
                        Spacer()
                    }
                }.padding(9)
            }
        }
    }
}
