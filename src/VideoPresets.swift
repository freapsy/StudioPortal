import Foundation

// Presets and explanations for MiniMax H3 Video Turbo4. Fixed sampler settings follow the lightx2v Turbo 4-step
// recommendation (euler, simple, video shift 6, CFG 1); frame grid 17n+5 at 24 fps; times measured on bigki.
// Steps: 6 is the default since 17.11.2026 – A/B test on bigki (124 frames, same seed): 4 steps 280 s, 6 steps 462 s,
// 6 clearly sharper (faces, hands, fabric). 4 stays for drafts.

struct VideoPreset {
    var choice: PresetChoice
    var width: Int
    var height: Int
    var frames: Int
    var steps = 6

    func apply(to s: inout VideoSettings) {
        s.width = width; s.height = height; s.frames = frames; s.steps = steps; s.cards = 2
    }

    func matches(_ s: VideoSettings) -> Bool {
        s.width == width && s.height == height && s.frames == frames && s.steps == steps
    }

    static let all: [VideoPreset] = [
        VideoPreset(choice: PresetChoice(id: "entwurf", title: "Entwurf", icon: "hare", note: "2 s · nur Bewegung prüfen"),
                    width: 864, height: 480, frames: 56, steps: 4),
        VideoPreset(choice: PresetChoice(id: "clip", title: "Clip 5 s", icon: "film", note: "Standard · 6 Schritte · ~8 min"),
                    width: 864, height: 480, frames: 124),
        VideoPreset(choice: PresetChoice(id: "schnell", title: "Schnell 5 s", icon: "bolt", note: "4 Schritte · ~5 min · weicher"),
                    width: 864, height: 480, frames: 124, steps: 4),
        VideoPreset(choice: PresetChoice(id: "hochkant", title: "Hochkant", icon: "iphone", note: "9:16 für Handy · 5 s"),
                    width: 480, height: 864, frames: 124),
        VideoPreset(choice: PresetChoice(id: "hd", title: "HD", icon: "sparkles.tv", note: "1280×704 · 5 s · deutlich länger"),
                    width: 1280, height: 704, frames: 124),
        VideoPreset(choice: PresetChoice(id: "lang", title: "Lang 8 s", icon: "timer", note: "864×480 · 192 Bilder"),
                    width: 864, height: 480, frames: 192),
    ]

    static let lengths: [(String, Int)] = [("2 s", 56), ("5 s", 124), ("8 s", 192), ("9,4 s", 226)]

    static let info: [ControlInfo] = [
        ControlInfo(name: "So entsteht ein Video",
                    what: "MiniMax H3 erzeugt Bild und Ton zusammen in einem Durchgang (Ton 32 kHz Stereo). Turbo4 ist eine auf 4 Schritte destillierte Fassung: Sampler euler, Zeitplan simple, Video-Shift 6, CFG 1 – genau die Werte, die lightx2v für Turbo4 empfiehlt; sie sind fest eingestellt.",
                    best: "Erst kurz und klein testen (Entwurf), dann den gewählten Seed in 5 s oder HD rendern."),
        ControlInfo(name: "Beschreibung",
                    what: "Reihenfolge: Motiv → Handlung → Kamera (z. B. „slow dolly-in, 35mm, shallow depth of field“) → Umgebung/Licht → am Ende „Audio: …“. Jedes Geräusch benennen und sagen, wann es kommt.",
                    best: "Englisch. In 5 s nicht gleichzeitig Dialog, Musik, Menschenmenge und Wetter verlangen – lieber ein, zwei Klänge. Natürliche Farben ausdrücklich nennen, sonst wird es oft dunkel und kontrastreich."),
        ControlInfo(name: "Länge",
                    what: "24 Bilder pro Sekunde. Das Modell arbeitet in einem Raster von 17n+5 Bildern (56, 124, 192, 226); andere Zahlen werden gerundet.",
                    best: "5 s (124 Bilder) ist der getestete Standard. Längere Clips dauern entsprechend länger und verlieren eher den Faden."),
        ControlInfo(name: "Format",
                    what: "Die offenen Gewichte sind bis 768p trainiert. 864×480 hat etwa 0,4 MP, 1280×704 knapp 0,9 MP.",
                    best: "864×480 für Ideen und die meisten Clips, 1280×704 nur für das fertige Video (mehr als doppelt so lange)."),
        ControlInfo(name: "Schritte",
                    what: "Wie oft das Video verfeinert wird. Jeder Schritt kostet auf den MI50 gleich viel Zeit.",
                    best: "6 (Standard): im Test auf bigki (5 s, gleicher Seed) deutlich schärfere Gesichter, Hände und Stoffe – 462 s statt 280 s mit 4 Schritten. 4 nur für Entwürfe. Mehr als 8 bringt bei Turbo nichts."),
        ControlInfo(name: "Grafikkarten",
                    what: "Das Modell wird über zwei Karten verteilt; sie tauschen pro Schritt Zwischenergebnisse über PCIe aus.",
                    best: "2 – drei Karten sind kaum schneller (der Austausch kostet ~25 s je Schritt), und die dritte bleibt für Bilder, Musik oder Blender frei."),
        ControlInfo(name: "Seed",
                    what: "Startwert. Gleicher Seed + gleiche Einstellungen = gleiches Video.",
                    best: "Beim Vergleichen festhalten und nur eine Sache ändern; zum Erkunden würfeln."),
    ]

    static let tips = [
        "Ton am Ende beschreiben: „Audio: rain on the window, distant thunder; no music, no speech“.",
        "Kameraangaben helfen: Brennweite, Bewegung (static shot, slow pan left, handheld).",
        "Nur privat nutzen: laut H3-Lizenz nicht in der EU veröffentlichen, nicht für Werbung.",
    ]

    static let points = [
        "sd.cpp-Video-Build für gfx906 (eigener ROCm-7.14-Build) statt PyTorch/ComfyUI.",
        "Modell über zwei Karten verteilt (Token-Aufteilung); die heißere Karte bekommt nur 42,5 % der Arbeit, damit beide gleich schnell fertig werden.",
        "Die zwei kühlsten Karten werden gewählt, Start erst unter 65 °C; die dritte Karte bleibt frei.",
        "Textmodell wird bei Bedarf von der SSD gestreamt (te=disk); Zufall auf der CPU für gleiche Ergebnisse bei gleichem Seed.",
        "Länge rastet auf das 17n+5-Raster des Modells ein; 6 Schritte als Standard (getestet: sichtbar mehr Details, 4 bleibt für Entwürfe).",
    ]

    static let improvements: [Improvement] = [
        Improvement(label: "Belegte Karten für 5 s", before: 3, after: 2, unit: "", note: "drei Karten waren kaum schneller (PCIe-Austausch ~25 s je Schritt)"),
    ]
}
