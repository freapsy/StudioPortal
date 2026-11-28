import Foundation
import AppKit

// Presets, formats and explanations for MiniMax H3 Image – values from the model card, Unsloth (sd-cli settings),
// ComfyUI docs/wiki, the ComfyUI template gist and Pixelailabs (realism workflow), checked against test series on bigki
// (same prompt and seed, 17.11.2026).

enum ImageFormat {
    static let aspects: [(String, Double)] = [("1:1", 1), ("4:3", 4.0 / 3), ("3:4", 3.0 / 4), ("3:2", 1.5), ("2:3", 2.0 / 3),
                                              ("16:9", 16.0 / 9), ("9:16", 9.0 / 16)]
    /// H3 Image is trained up to ~16 MP; these are the native sizes from the model card.
    static let native16: [String: (Int, Int)] = ["1:1": (4096, 4096), "4:3": (4736, 3552), "3:4": (3552, 4736), "3:2": (5024, 3360),
                                                 "2:3": (3360, 5024), "16:9": (5472, 3072), "9:16": (3072, 5472)]
    /// resolution levels in megapixels with the measured time for one image on the three MI50
    static let levels: [(title: String, mp: Double, time: String)] = [("Entwurf · 1 MP", 1, "~1¼ min"), ("Gut · 4 MP", 4, "~2¼ min"),
                                                                       ("Maximal · 16 MP", 16, "~12 min")]

    static func round32(_ value: Double) -> Int { max(256, Int((value / 32).rounded()) * 32) }

    static func size(aspect: String, mp: Double) -> (Int, Int) {
        if mp >= 16, let native = native16[aspect] { return native }
        let ratio = aspects.first { $0.0 == aspect }?.1 ?? 1
        if aspect == "1:1" { let side = round32((mp * 1_048_576).squareRoot()); return (side, side) }
        return (round32((mp * 1_048_576 * ratio).squareRoot()), round32((mp * 1_048_576 / ratio).squareRoot()))
    }

    /// (aspect, level) of the current size, nil when it is a custom size
    static func match(_ width: Int, _ height: Int) -> (String, Double)? {
        for (aspect, _) in aspects { for level in levels where size(aspect: aspect, mp: level.mp) == (width, height) { return (aspect, level.mp) } }
        return nil
    }

    static func aspect(of width: Int, _ height: Int) -> String {
        let ratio = Double(width) / Double(max(height, 1))
        return aspects.min { abs(log($0.1 / ratio)) < abs(log($1.1 / ratio)) }?.0 ?? "1:1"
    }

    static func megapixels(_ width: Int, _ height: Int) -> Double { Double(width * height) / 1_048_576 }
}

struct ImagePreset {
    var choice: PresetChoice
    var aspect: String?          // nil = keep the current aspect
    var mp: Double
    var sampler = "euler"
    var scheduler = ""           // "" = H3 sigma profile
    var steps = 6
    var cfg = 1.0
    var editing = false
    var speed = false
    /// extra sd-cli arguments (lcm noise schedule for portraits)
    var extra = ""

    func apply(to settings: inout Settings) {
        var aspect = self.aspect ?? ImageFormat.aspect(of: settings.width, settings.height)
        if editing {
            settings.mode = "Bearbeiten"
            // sd-cli crops the references to the output size – keep Picture 1's aspect
            if let first = settings.references.first, let image = NSImage(contentsOf: first.url),
               let rep = image.representations.first, rep.pixelsWide > 0 {
                aspect = ImageFormat.aspect(of: rep.pixelsWide, rep.pixelsHigh)
            }
            if !settings.seedLocked { settings.seed = Int64.random(in: 0...Int64(Int32.max)) }
        }
        (settings.width, settings.height) = ImageFormat.size(aspect: aspect, mp: mp)
        settings.sampler = sampler; settings.scheduler = scheduler; settings.steps = steps; settings.cfg = cfg
        settings.rng = "cpu"; settings.flashAttention = true; settings.vaeTiling = true
        if speed { settings.setSpeedLora(true) } else { settings.speedLora = nil }
        settings.extra = extra
    }

    func matches(_ s: Settings) -> Bool {
        let sizeOK = aspect == nil ? abs(ImageFormat.megapixels(s.width, s.height) - mp) < mp * 0.12
                                   : ImageFormat.size(aspect: aspect!, mp: mp) == (s.width, s.height)
        return sizeOK && s.sampler == sampler && s.scheduler == scheduler && s.steps == steps && s.cfg == cfg
            && (editing ? s.mode == "Bearbeiten" : s.mode == "Neu") && s.usesSpeedLora == speed && s.extra == extra
    }

    static let all: [ImagePreset] = [
        ImagePreset(choice: PresetChoice(id: "entwurf", title: "Schnell", icon: "hare", note: "4 MP · ~1¼ min · Speed-LoRA"),
                    aspect: nil, mp: 4, scheduler: "simple", steps: 2, speed: true),
        ImagePreset(choice: PresetChoice(id: "foto", title: "Foto realistisch", icon: "camera", note: "Menschen, Alltag · ~2¼ min"),
                    aspect: "1:1", mp: 4),
        ImagePreset(choice: PresetChoice(id: "portraet", title: "Porträt", icon: "person.crop.rectangle", note: "3:4 · natürliche Haut · ~2¼ min"),
                    aspect: "3:4", mp: 4, sampler: "lcm", scheduler: "simple", extra: "--extra-sample-args noise_scale_start=1.1,noise_scale_end=0.9,noise_clip_std=0"),
        ImagePreset(choice: PresetChoice(id: "landschaft", title: "Landschaft", icon: "mountain.2", note: "16:9 · 4 MP · ~2¼ min"),
                    aspect: "16:9", mp: 4),
        ImagePreset(choice: PresetChoice(id: "maximal", title: "Maximale Details", icon: "sparkle.magnifyingglass", note: "Endbild · 16 MP · ~12 min"),
                    aspect: nil, mp: 16),
        ImagePreset(choice: PresetChoice(id: "bearbeiten", title: "Bearbeiten", icon: "wand.and.stars", note: "Picture 1 ändern · 4 MP"),
                    aspect: nil, mp: 4, editing: true),
    ]

    static let info: [ControlInfo] = [
        ControlInfo(name: "Voreinstellungen",
                    what: "Setzen Größe, Sampler, Zeitplan, Schritte und CFG auf getestete Werte. Danach kannst du alles von Hand ändern – die Markierung verschwindet dann.",
                    best: "Foto realistisch für Menschen, Schnell zum Ausprobieren des Prompts, Maximale Details nur für das fertige Bild."),
        ControlInfo(name: "Format und Auflösung",
                    what: "Seitenverhältnis und Pixelzahl. H3 Image ist bis etwa 16 Megapixel trainiert: mehr Pixel geben feinere Haut, Haare, Stoff und Schrift. Die Zeit wächst langsamer als die Pixel (4 MP dauert nur ~1,8× so lange wie 1 MP).",
                    best: "Alle Quellen: unter ~4 MP leiden Gesichter, Zähne und Haut – 1 MP nur, um Bildaufbau und Prompt zu prüfen. 4 MP für gute Bilder, 16 MP (native Größen) für das Endbild; darüber (bis ~20 MP) bringt nichts mehr. Kanten sind immer Vielfache von 32."),
        ControlInfo(name: "Speed-LoRA (2 Schritte)",
                    what: "Eine Zusatz-LoRA (pDMD, Apache-2.0), die H3 Image auf 2 statt 6 Schritte destilliert; dazu euler, Zeitplan simple, Shift 12. Liegt auf bigki unter ~/.local/share/3d-modelle-app/loras.",
                    best: "Im Test bei 4 MP: 76 s statt 136 s, sauber und scharf, Haut etwas glatter und weniger Sommersprossen als mit 6 Schritten. Nur bis ~4 MP: bei 16 MP (272 s statt 640 s) entstehen Mosaik-Artefakte auf Haut und Haaren – die App blockt das. Gleicher Seed ergibt mit und ohne LoRA ein anderes Bild – für das Endbild mit 6 Schritten neu würfeln. 2 Schritte ohne LoRA sind verschwommen."),
        ControlInfo(name: "Schritte",
                    what: "Wie oft das Bild aus dem Rauschen verfeinert wird. H3 Image ist auf 6 Schritte destilliert (trainiert).",
                    best: "6 – so empfehlen es MiniMax, ComfyUI und Unsloth übereinstimmend. Mehr Schritte bringen nichts und können das Bild überschärfen; weniger wird matschig. Eine Zahl ≠ 6 schaltet den H3-Zeitplan ab."),
        ControlInfo(name: "CFG",
                    what: "Wie stark der Prompt gegen ein „freies“ Bild durchgedrückt wird. Über 1 rechnet das Modell jeden Schritt doppelt (mit und ohne Prompt).",
                    best: "1,0 – das Modell ist dafür destilliert. Im Test (CFG 2 + Negativ-Prompt): doppelte Zeit, harter Kontrast, übertriebene Sommersprossen. CFG > 1 geht nur mit Negativ-Prompt (-n …)."),
        ControlInfo(name: "Sampler",
                    what: "Das Rechenverfahren, mit dem pro Schritt vom Rauschen zum Bild gegangen wird.",
                    best: "euler (Referenz von MiniMax): im Test die meiste Hautstruktur (Poren, Sommersprossen). lcm mit Zeitplan „simple“: gleich schnell, Haut glatter und gleichmäßiger – gut für weiche Porträts. Test bei 16 MP (gleicher Seed, je ~10¾ min): euler zeigt jede Sommersprosse, wirkt aber rau und etwas überschärft; lcm gibt klare Augen, Wimpern und natürliche, glattere Haut, folgt „freckles“ aber schwächer – so empfiehlt es auch Pixelailabs für Gesichter. Mit Rauschplan (lcm-Rauschstärke 1,1 → 0,9, Pixelailabs-Rezept, in „Porträt“ eingestellt) wird die Haut bei gleicher Zeit etwas lebendiger: feinere Poren, mehr Struktur an Lippen und Zähnen. dpm++/heun sind für Modelle mit 20–50 Schritten gedacht; heun braucht die doppelte Zeit."),
        ControlInfo(name: "Scheduler (Zeitplan)",
                    what: "Verteilt die Rauschstärken auf die Schritte – welcher Schritt grob und welcher fein arbeitet.",
                    best: "„H3-Zeitplan“ (--sigmas minimax-h3-image, wie bei Unsloth für sd-cli). simple nur zusammen mit lcm (so auch im Pixelailabs-Workflow). karras/exponential stammen aus Stable Diffusion und passen hier nicht."),
        ControlInfo(name: "RNG",
                    what: "Der Zufallsgenerator für das Startrauschen.",
                    best: "cpu: gleicher Seed gibt auf jedem Rechner dasselbe Bild (Standard des H3-Skripts). cuda/std_default ergeben bei gleichem Seed andere Bilder."),
        ControlInfo(name: "Seed",
                    what: "Startwert des Rauschens. Gleicher Seed + gleiche Einstellungen = gleiches Bild.",
                    best: "Der Seed macht bei H3 viel aus: pro Prompt mehrere Bilder (Anzahl 2–4) und das beste nehmen. Schloss zu, wenn du nur den Prompt verfeinern willst. Beim Bearbeiten nie Seed und Größe des Ausgangsbilds nehmen – sonst überschärft und die Anweisung wird ignoriert (Unsloth)."),
        ControlInfo(name: "Flash Attention",
                    what: "Speichersparende Berechnung der Aufmerksamkeit im Bildmodell (läuft im eigenen gfx906-Build).",
                    best: "An lassen – aus braucht deutlich mehr Grafikspeicher und ist langsamer."),
        ControlInfo(name: "VAE-Kacheln",
                    what: "Das fertige Bild wird in 256-px-Kacheln aus dem latenten Raum dekodiert statt am Stück.",
                    best: "An lassen – ab ~2 MP sonst zu wenig Speicher auf der 32-GB-Karte; Nähte sind nicht sichtbar."),
        ControlInfo(name: "Weitere sd-cli-Argumente",
                    what: "Für Experimente, z. B. --sigmas oder -n (Negativ-Prompt, nur mit CFG > 1).",
                    best: "Leer lassen, außer du weißt genau, was du testen willst."),
    ]

    static let tips = [
        "Lange, konkrete Beschreibung auf Englisch, 80–150 Wörter: Motiv (Alter, Haare, Haut), Haltung und Blick, Kleidung und Gegenstände, Hintergrund, Licht, Kamera (z. B. „iPhone 15 Pro, 24mm, f/1.8, natural phone HDR“) und Echtheit („visible pores, not retouched, not cinematic, not studio“). Kurze Prompts geben glatte Puppengesichter, und das Modell wählt Ort und Kleidung selbst (im Test: anderes Café, anderes Outfit).",
        "Es gibt keinen Negativ-Prompt bei CFG 1 – Unerwünschtes positiv umschreiben („natural skin, no makeup“ statt „kein Make-up“).",
        "Mehrere Seeds probieren: Anzahl 2–4 und das beste nehmen. Ein Seed ergibt nur bei gleicher Größe und gleichen Einstellungen dasselbe Bild – „Schnell“ (Speed-LoRA) eignet sich zum Prüfen des Prompts, nicht zum Vorauswählen des Seeds.",
        "Porträt als Endbild: „Porträt“ wählen, dann Stufe „Maximal · 16 MP“ – lcm bleibt eingestellt.",
        "Schrift im Bild in Anführungszeichen setzen – H3 schreibt Etiketten und Titel zuverlässig.",
        "Bearbeiten: Picture 1 ist das Bild, das geändert wird; das Ergebnis übernimmt sein Format (macht die Voreinstellung automatisch). Im Prompt ausdrücklich sagen, was bleibt („keep the face, pose and framing of <Picture 1>“) und was sich ändert.",
    ]

    static let improvements: [Improvement] = [
        Improvement(label: "Pixel pro Sekunde (1 MP → 4 MP)", before: 14, after: 31, unit: "k", lowerIsBetter: false,
                    note: "4 MP dauert 136 s statt 75 s – viermal so viele Pixel für 1,8× Zeit."),
        Improvement(label: "4-MP-Bild mit Speed-LoRA", before: 136, after: 76, unit: "s",
                    note: "2 statt 6 Schritte: Rechnen 50 s statt 110 s; Textmodell und VAE bleiben gleich."),
        Improvement(label: "Grafikkarten für ein Bild", before: 1, after: 3, unit: "", lowerIsBetter: false,
                    note: "Das Modell passt nicht auf eine 32-GB-Karte; es wird schichtweise auf alle drei MI50 verteilt."),
    ]
    static let points = [
        "stable-diffusion.cpp selbst für gfx906 gebaut (eigener ROCm-7.14-Build, AMD unterstützt die MI50 offiziell nicht mehr).",
        "Bildmodell schichtweise über alle drei Karten (--split-mode layer), Textmodell Qwen3-VL-32B wird bei Bedarf von der SSD gestreamt (te=disk) statt dauerhaft Grafikspeicher zu belegen.",
        "Flash Attention im gfx906-Build, VAE in Kacheln auf Karte 2, Zufall auf der CPU für gleiche Bilder bei gleichem Seed.",
        "Voreinstellungen aus Testreihen und Quellen (MiniMax, ComfyUI, Unsloth, Pixelailabs): 6 Schritte, CFG 1, euler + H3-Zeitplan, mindestens 4 MP für fertige Bilder, lange Kamera-Prompts.",
    ]
}
