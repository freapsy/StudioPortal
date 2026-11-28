import Foundation

// Presets and explanations for MiniMax Music 3 (mm-synth). Sources: official model card (MiniMaxAI/MiniMax-Music3),
// ComfyUI generation-settings node, Fuser prompt guide; times measured on bigki (17.11.2026).

struct MusicPreset {
    var choice: PresetChoice
    var steps: Int
    var variants: Int
    var lmCfg = 1.7
    var ditCfg = 1.7
    var topK = 50
    var instrumental = false

    func apply(to s: inout MusicSettings) {
        s.steps = steps; s.variants = variants; s.lmCfg = lmCfg; s.ditCfg = ditCfg; s.topK = topK
        if instrumental {
            s.lyrics = MusicSettings.instrumental
            if !s.caption.localizedCaseInsensitiveContains("no vocals") {
                s.caption = s.caption.trimmingCharacters(in: .whitespacesAndNewlines) + (s.caption.isEmpty ? "" : " ") + "No vocals. Purely instrumental."
            }
        }
    }

    func matches(_ s: MusicSettings) -> Bool {
        s.steps == steps && s.variants == variants && s.lmCfg == lmCfg && s.ditCfg == ditCfg && s.topK == topK
            && (!instrumental || s.lyrics == MusicSettings.instrumental)
    }

    static let all: [MusicPreset] = [
        MusicPreset(choice: PresetChoice(id: "skizze", title: "Skizzen", icon: "square.stack.3d.up", note: "3 Varianten parallel · ~5 min"),
                    steps: 8, variants: 3),
        MusicPreset(choice: PresetChoice(id: "voll", title: "Song fertig", icon: "music.note.list", note: "1 Song · volle Qualität · ~6 min"),
                    steps: 30, variants: 1),
        MusicPreset(choice: PresetChoice(id: "stimme", title: "Klare Stimme", icon: "mic", note: "Gesang klarer getrennt"),
                    steps: 30, variants: 1, ditCfg: 1.5),
        MusicPreset(choice: PresetChoice(id: "instrumental", title: "Instrumental", icon: "pianokeys", note: "ohne Gesang · 3 Skizzen"),
                    steps: 8, variants: 3, instrumental: true),
        MusicPreset(choice: PresetChoice(id: "abwechslung", title: "Mehr Abwechslung", icon: "shuffle", note: "freier, überraschender · 3 Skizzen"),
                    steps: 8, variants: 3, lmCfg: 1.5, topK: 100),
    ]

    static let info: [ControlInfo] = [
        ControlInfo(name: "So entsteht ein Song",
                    what: "Zwei Stufen: Ein Sprachmodell (8 Mrd. Parameter) schreibt zuerst „Audio-Codes“ – Melodie, Aufbau, Gesangslinie, Länge. Danach malt ein Diffusionsmodell (DiT) daraus in 8-Sekunden-Fenstern den Klang. Die Codes werden gespeichert: „In voller Qualität“ rechnet nur den Klang neu, die Melodie bleibt gleich.",
                    best: "Erst Skizzen mit 8 Schritten, die beste Variante dann mit 30 Schritten in voller Qualität."),
        ControlInfo(name: "Beschreibung",
                    what: "Steuert Stil, Stimme und Instrumente. Am besten dreiteilig (wie in der offiziellen Modellkarte): 1) Global – Genre, BPM, Tonart, Stimmung, Produktion; 2) Gesang – Geschlecht, Klangfarbe, Stil, Harmonien, Effekte; 3) Arrangement – Instrumente je Abschnitt, Groove, Bass, Schlagzeug, Raum.",
                    best: "Ausführlich auf Englisch. Einzeiler führen zu verschluckten Zeilen und undeutlichem Gesang. BPM und Tonart sind nur grobe Ziele."),
        ControlInfo(name: "Songtext",
                    what: "Nur diese Abschnitte kennt das Modell: [intro] [verse] [pre-chorus] [chorus] [post-chorus] [bridge] [instrumental] [solo] [outro] – jeder auf einer eigenen Zeile, darunter eine gesungene Zeile pro Zeile.",
                    best: "Kein Text auf derselben Zeile wie die Klammer (wird nicht gesungen). Instrumental: nur [intro] [instrumental] [solo] [outro] und „No vocals“ in die Beschreibung – [instrumental] allein ergibt oft Summen ohne Worte."),
        ControlInfo(name: "Länge",
                    what: "Obergrenze bis 6 min; das Modell endet oft früher, wenn der Text zu Ende ist. Eine andere Länge mit gleichem Seed ergibt einen anderen Song, nicht nur einen kürzeren.",
                    best: "Faustregel ~6 s pro gesungener Zeile plus Intro/Outro. Endet der Song hart an der Grenze → länger stellen; singt er am Ende fremde Worte → kürzer oder mehr Text."),
        ControlInfo(name: "Qualität (Schritte)",
                    what: "Diffusionsschritte je 8-Sekunden-Fenster für den Klang. Mehr Schritte = sauberere Höhen, weniger Rauschen, aber jede Minute dauert länger.",
                    best: "8 zum Vergleichen von Melodien, 30 für das Ergebnis (Empfehlung der Modellkarte/ComfyUI 30–40). Über 40 bringt kaum etwas."),
        ControlInfo(name: "Varianten",
                    what: "Bis zu drei Songs mit Seed, Seed+1, Seed+2. Jede Variante rechnet auf einer eigenen MI50.",
                    best: "3 bei Skizzen – kostet kaum mehr Zeit als eine, solange alle Karten frei sind."),
        ControlInfo(name: "Melodie-Seed",
                    what: "Startwert des Sprachmodells: bestimmt Melodie, Aufbau und Länge. Gleiche Eingaben + Seed = gleicher Song.",
                    best: "Festhalten (Schloss), wenn du nur die Beschreibung des Klangs änderst."),
        ControlInfo(name: "Klang-Seed",
                    what: "Startwert des Diffusionsmodells: Feinheiten des Klangs bei gleicher Melodie.",
                    best: "Meist egal; neu würfeln, wenn ein Song bei gleicher Melodie verwaschen klingt."),
        ControlInfo(name: "LM-CFG",
                    what: "Wie streng das Sprachmodell der Beschreibung folgt.",
                    best: "1,7 (Standard). 1,4–1,5 natürlicher und freier; über 2,5 oft künstlich oder mit Aussetzern."),
        ControlInfo(name: "DiT-CFG",
                    what: "Wie stark der Klang an Beschreibung und Codes gebunden wird.",
                    best: "1,7 (Standard). 1,5 trennt Stimme und Instrumente oft sauberer; zu hohe Werte klingen gepresst und angestrengt."),
        ControlInfo(name: "Top-K",
                    what: "Aus wie vielen wahrscheinlichsten Möglichkeiten das Sprachmodell pro Schritt wählt.",
                    best: "50. Kleiner = vorhersehbarer, wiederholt sich eher; 100+ = mehr Überraschungen, manchmal unruhig."),
        ControlInfo(name: "Format",
                    what: "MP3 zum Anhören und Teilen, WAV (16 Bit) für die Weiterbearbeitung.",
                    best: "MP3 für Skizzen, WAV für den fertigen Song."),
    ]

    static let tips = [
        "Vorlagen (oben rechts) sind die offiziellen Demos – gut als Startpunkt für Beschreibung und Aufbau.",
        "Wechsel im Song in die Beschreibung schreiben („chorus opens up with wide stereo synths“), nicht in den Songtext.",
        "Veröffentlichte Musik als KI-erzeugt kennzeichnen.",
    ]

    static let points = [
        "Statt PyTorch läuft minimaxmusic.cpp (ggml/C++), mit HIP für gfx906 gebaut (eigener ROCm-7.14-Build) – ein Modell pro Karte.",
        "Drei Varianten rechnen gleichzeitig auf drei MI50 statt nacheinander.",
        "Zweistufig mit gespeicherten Audio-Codes: Skizzen mit 8 Schritten, „In voller Qualität“ rechnet nur den Klang mit 30 Schritten neu – die Melodie bleibt.",
        "Start erst unter 65 °C, damit die Karten bei langen Songs nicht in die Drosselung laufen; hält die gemeinsame GPU-Sperre.",
    ]

    /// measured on bigki 17.11.2026 with a 60-s song (same lyrics and seed)
    static let improvements: [Improvement] = [
        Improvement(label: "3 Skizzen (60-s-Song, 8 Schritte)", before: 3 * 203, after: 284, unit: "s",
                    note: "parallel auf drei Karten statt dreimal nacheinander (eine Skizze: 203 s)"),
        Improvement(label: "Volle Qualität (30 Schritte)", before: 480, after: 379, unit: "s",
                    note: "nur der Klang wird neu berechnet; das Sprachmodell (~100 s, geschätzt aus Skizze vs. Vollrender) läuft nicht noch einmal"),
    ]

    /// ~6 s per sung line plus intro/outro
    static func suggestedLength(_ lyrics: String) -> Double? {
        let sung = lyrics.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("[") }
        guard !sung.isEmpty else { return nil }
        return min(360, (max(30, Double(sung.count) * 6 + 20) / 5).rounded() * 5)
    }
}
