import Foundation

/// How to use each StudioPortal function well – for agents (`guide` MCP tool, `studioportal guide <thema>`).
/// Built from the same data as the app's presets and ⓘ explanations (ImagePreset/MusicPreset/VideoPreset), so agents and
/// humans always get the same, tested knowledge. Hand-written parts: workflow, prompt templates, parameter mapping.
enum Guide {
    static let topics = ["bild", "musik", "sprache", "telefon", "video", "3d", "figur", "blender", "vergleich"]

    static func make(_ topic: String?) throws -> [String: Any] {
        let key = (topic ?? "").lowercased()
            .replacingOccurrences(of: "image", with: "bild").replacingOccurrences(of: "music", with: "musik")
            .replacingOccurrences(of: "speech", with: "sprache").replacingOccurrences(of: "phone", with: "telefon")
            .replacingOccurrences(of: "bilder", with: "bild")
        switch key {
        case "", "uebersicht", "übersicht", "alle":
            return ["themen": topics,
                    "hinweis": "guide topic=<thema> liefert für jede Funktion: Ablauf, Voreinstellungen mit Werten, jeden Regler erklärt (was er tut, was am besten ist), Tipps und die Parameter des Werkzeugs. Das ist dasselbe Wissen, das die App in ihren ⓘ-Erklärungen zeigt."]
        case "bild": return image()
        case "musik": return music()
        case "sprache": return speech()
        case "telefon": return phone()
        case "video": return video()
        case "3d": return model3D()
        case "figur", "figuren": return figure()
        case "blender": return blender()
        case "vergleich", "compare": return compare()
        default: throw StudioError.message("topic: " + topics.joined(separator: ", "))
        }
    }

    private static func controls(_ items: [ControlInfo]) -> [[String: String]] {
        items.map { ["regler": $0.name, "was": $0.what, "am_besten": $0.best] }
    }

    // MARK: - Bild

    private static func image() -> [String: Any] {
        let presets: [[String: Any]] = ImagePreset.all.map { p in
            var values: [String: Any] = ["megapixels": p.mp, "sampler": p.sampler, "scheduler": p.scheduler.isEmpty ? "h3" : p.scheduler,
                                         "steps": p.steps, "cfg": p.cfg]
            values["aspect"] = p.aspect ?? "bleibt"
            if p.speed { values["speed_lora"] = true }
            if p.editing { values["mode"] = "bearbeiten (references nötig)" }
            if !p.extra.isEmpty { values["extra"] = p.extra }
            return ["preset": p.choice.id, "titel": p.choice.title, "wofuer": p.choice.note, "werte": values]
        }
        return [
            "modell": "MiniMax H3 Image (Q8, sd-cli auf allen drei MI50), destilliert auf 6 Schritte, CFG 1",
            "werkzeug": "create_image",
            "ablauf": [
                "1. Prompt auf Englisch, 80–150 Wörter (Vorlage unten).",
                "2. Zum Prüfen von Bildaufbau und Prompt: preset=entwurf (4 MP, ~1¼ min, Speed-LoRA) oder megapixels=1.",
                "3. Gutes Bild: preset=foto/portraet/landschaft mit count=2–4 (der Seed macht viel aus) – das beste nehmen.",
                "4. Endbild: like=<pfad des besten Bilds> megapixels=16 (gleicher Prompt, ~12 min). Achtung: anderer Seed/Größe = anderes Bild – bei 16 MP lieber 2 Seeds.",
                "5. Ändern statt neu: references=[bild], preset=bearbeiten, Prompt mit <Picture 1> (sagen, was bleibt und was sich ändert).",
            ],
            "prompt_vorlage": "[Motiv: Alter, Haare, Haut, Ausdruck] [Haltung, Blick] [Kleidung, Gegenstände] [Ort, Hintergrund] [Licht, Tageszeit] [Kamera: z. B. iPhone 15 Pro, 24mm, f/1.8, natural phone HDR] [Echtheit: visible pores, not retouched, not cinematic]",
            "voreinstellungen": presets,
            "formate": ["seitenverhaeltnisse": ImageFormat.aspects.map(\.0),
                        "stufen": ImageFormat.levels.map { ["titel": $0.title, "megapixels": $0.mp, "dauer_je_bild": $0.time] }],
            "regler": controls(ImagePreset.info),
            "tipps": ImagePreset.tips,
            "parameter": [
                "prompt": "Pflicht", "preset": ImagePreset.all.map(\.choice.id).joined(separator: "|"),
                "count": "1–4 (Seeds hintereinander)", "aspect": ImageFormat.aspects.map(\.0).joined(separator: "|"),
                "megapixels": "1|4|16 (oder width/height, Vielfache von 32)", "seed": "Zahl",
                "references": "Liste von Bildpfaden → Bearbeiten (<Picture 1> …)",
                "steps / cfg / sampler / scheduler / rng": "wie in der App (Erweitert)",
                "speed_lora": "true = 2 Schritte mit Speed-LoRA (nur bis ~4 MP)",
                "flash_attention / vae_tiling": "true (Standard) – nur zum Testen ausschalten",
                "extra": "weitere sd-cli-Argumente, z. B. \"-n 'blurry'\" (Negativ-Prompt nur mit cfg > 1)",
                "like": "Pfad eines früheren Bilds: übernimmt Prompt und alle Einstellungen (= „Übernehmen“ in der App); mit new_seed=true neuer Seed (= „Variieren“). Danach angegebene Parameter überschreiben.",
            ],
        ]
    }

    // MARK: - Musik

    private static func music() -> [String: Any] {
        let presets: [[String: Any]] = MusicPreset.all.map { p in
            var values: [String: Any] = ["steps": p.steps, "variants": p.variants, "lm_cfg": p.lmCfg, "dit_cfg": p.ditCfg, "top_k": p.topK]
            if p.instrumental { values["lyrics"] = "instrumental (+ „No vocals. Purely instrumental.“ in der Beschreibung)" }
            return ["preset": p.choice.id, "titel": p.choice.title, "wofuer": p.choice.note, "werte": values]
        }
        return [
            "modell": "MiniMax Music 3 (minimaxmusic.cpp auf den MI50): Sprachmodell schreibt Melodie/Aufbau, Diffusion malt den Klang",
            "werkzeuge": ["create_music", "render_music_full", "music_examples"],
            "ablauf": [
                "1. Optional music_examples: offizielle Demos als Vorlage für Beschreibung und Songtext.",
                "2. Beschreibung dreiteilig auf Englisch (Vorlage unten), Songtext mit Abschnitts-Tags.",
                "3. Länge ≈ 6 s je gesungene Zeile + 20 s (Obergrenze; das Modell endet früher, wenn der Text aus ist).",
                "4. preset=skizze: 3 Varianten parallel (8 Schritte, ~5 min) – anhören bzw. dem Nutzer vorlegen.",
                "5. Die beste mit render_music_full in voller Qualität (30 Schritte): gleiche Melodie, sauberer Klang (~6 min). Mehrere gleichzeitig möglich (je eine Karte).",
                "6. Andere Melodie mit gleicher Beschreibung: like=<song> new_seed=true. Gleiche Melodie, anderer Klang: like=<song> und caption ändern (Melodie-Seed bleibt).",
            ],
            "beschreibung_vorlage": "Global: <Genre>, <BPM> BPM, <Tonart>, <Stimmung>, <Produktion>. Vocals: <Geschlecht, Klangfarbe, Stil, Harmonien, Effekte>. Arrangement: <Instrumente je Abschnitt, Groove, Bass, Schlagzeug, Raum, was sich im Refrain ändert>.",
            "songtext_vorlage": "[intro]\n[verse]\nZeile 1\nZeile 2\n[pre-chorus]\n…\n[chorus]\n…\n[bridge]\n…\n[chorus]\n…\n[outro]",
            "erlaubte_abschnitte": ["[intro]", "[verse]", "[pre-chorus]", "[chorus]", "[post-chorus]", "[bridge]", "[instrumental]", "[solo]", "[outro]"],
            "voreinstellungen": presets,
            "regler": controls(MusicPreset.info),
            "tipps": MusicPreset.tips,
            "parameter": [
                "caption": "Pflicht – die Beschreibung", "lyrics": "Songtext mit Tags", "instrumental": "true = ohne Gesang",
                "preset": MusicPreset.all.map(\.choice.id).joined(separator: "|"),
                "duration": "Sekunden (Obergrenze, 10–360)", "variants": "1–3 (je eine MI50, parallel)",
                "quality": "preview (8 Schritte) | full (30)", "steps": "Diffusionsschritte direkt",
                "format": "mp3|wav", "seed": "Melodie-Seed (Varianten: seed, seed+1, seed+2)", "sound_seed": "Klang-Seed",
                "lm_cfg / dit_cfg / top_k": "wie in der App (Erweitert), Standard 1,7 / 1,7 / 50",
                "like": "Pfad eines früheren Songs: übernimmt Beschreibung, Songtext und Melodie-Seed (= „Übernehmen“); new_seed=true = neue Melodie (= „Variieren“)",
            ],
            "kennzeichnung": "Veröffentlichte Musik als KI-erzeugt kennzeichnen.",
        ]
    }

    // MARK: - Sprache & Telefon

    private static func speech() -> [String: Any] {
        [
            "modell": "Fish Audio Drama 3 V2 (35B MoE, 3B aktiv, Q4_K Experten + FP32 Router + Q8 Backbone, 0xShug0/audio.cpp auf 1× MI50) + optional Qwen3-TTS 1.7B",
            "werkzeuge": ["create_speech", "speech"],
            "ablauf": [
                "1. Text auf Deutsch (oder 82 weitere Sprachen) eingeben; optional Regie-Tags wie [calm], [laughs], [sighs], [whisper] oder Sprecherwechsel <|speaker:0|>/<|speaker:1|>.",
                "2. Optional voice_ref (5–25 s WAV/M4A/MP3) + reference_text zum Voice Cloning angeben (nur mit Einwilligung der Person).",
                "3. Der Sprach-Server bleibt auf 1× MI50 warm (Auto-Stopp nach 15 min Pause); die beiden anderen MI50 bleiben frei.",
            ],
            "parameter": [
                "text": "Pflicht – zu sprechender Text",
                "engine": "drama-3 (Standard) | qwen3-tts",
                "voice_ref": "Optionaler Pfad zu einer Referenz-Audiodatei",
                "reference_text": "Transkript der Referenzaufnahme (verbessert Ähnlichkeit)",
                "temperature": "0.2–1.4 (Standard 1.0; für ruhige Telefonstimmen 0.75–0.85)",
                "top_p": "0.5–1.0 (Standard 0.9)",
                "seed": "Zahl für konstante Stimme ohne Referenz",
            ],
            "lizenz": "Fish Audio Community License v1.0 – Built with Fish Audio. Keine echten Stimmen ohne Einwilligung klonen.",
        ]
    }

    private static func phone() -> [String: Any] {
        [
            "modell": "2+1 GPU-Split auf bigki: GPU 0+2 = Qwen 3.8 Flash (Strata 2-Karten, 32k Kontext), GPU 1 (OCuLink) = Drama 3 / Qwen3-TTS, i5-11600K AVX-512 CPU = Nemotron 3.5 ASR (de-DE) + Pipecat Smart Turn v3.2",
            "werkzeuge": ["phone"],
            "ablauf": [
                "1. In StudioPortal im Tab „Telefon-Test“ Zielbetrieb & Website-Fehler eintragen (oder Akquise-Vorlage wählen).",
                "2. Auf „Anruf simulieren“ klicken – macOS nutzt Apple VoiceProcessingIO (AEC) + weiches Ducking/Fade-Out für natürliches Dazwischenreden.",
                "3. Gespeicherte Testanrufe (Transkript + Audio) landen unter ~/Music/StudioPortal-Sprache/Anrufe/.",
            ],
        ]
    }

    // MARK: - Video

    private static func video() -> [String: Any] {
        let presets: [[String: Any]] = VideoPreset.all.map { p in
            ["preset": p.choice.id, "titel": p.choice.title, "wofuer": p.choice.note,
             "werte": ["width": p.width, "height": p.height, "frames": p.frames, "sekunden": Double(p.frames) / 24, "steps": p.steps]]
        }
        return [
            "modell": "MiniMax H3 Turbo4 (Q6_K) – Bild und Ton in einem Durchgang, auf zwei MI50",
            "werkzeug": "create_video (lang: wait=false, dann get_job)",
            "ablauf": [
                "1. Prompt auf Englisch: Motiv → Handlung → Kamera → Umgebung/Licht → am Ende „Audio: …“.",
                "2. preset=entwurf (2 s, 4 Schritte) um Bewegung und Ton zu prüfen.",
                "3. Gefällt es: like=<video> preset=clip (5 s, 6 Schritte, ~8 min) – gleicher Seed, gleiche Beschreibung.",
                "4. Fertiges Video: preset=hd (1280×704) oder hochkant.",
            ],
            "prompt_vorlage": "A <Motiv> <Handlung>. <Kamera: slow dolly-in, 35mm, shallow depth of field>. <Umgebung, Licht, natürliche Farben>. Audio: <1–2 Geräusche und wann>; no music.",
            "voreinstellungen": presets,
            "laengen": VideoPreset.lengths.map { ["titel": $0.0, "frames": $0.1] },
            "formate": VideoSettings.sizes.map { ["name": $0.0, "width": $0.1, "height": $0.2] },
            "regler": controls(VideoPreset.info),
            "tipps": VideoPreset.tips,
            "parameter": [
                "prompt": "Pflicht", "preset": VideoPreset.all.map(\.choice.id).joined(separator: "|"),
                "seconds": "Länge (wird aufs 17n+5-Raster gerundet)", "aspect": "16:9|9:16|1:1|16:9-hd",
                "steps": "4 (Entwurf) | 6 (Standard)", "cards": "2 (empfohlen) | 3", "seed": "Zahl",
                "like": "Pfad eines früheren Videos: Beschreibung, Länge, Format, Schritte und Seed übernehmen; new_seed=true = Variieren",
            ],
            "lizenz": "Nur privat: nicht in der EU veröffentlichen, nicht für Werbung.",
        ]
    }

    // MARK: - 3D, Figur, Blender, Vergleich

    private static func model3D() -> [String: Any] {
        [
            "modell": "Hunyuan3D-2mv (Tencent) auf bigki",
            "werkzeuge": ["image_to_3d", "import_model"],
            "ablauf": [
                "1. Bilder derselben Pose: front (Pflicht), dazu left/back/right für mehr Genauigkeit. Hintergründe werden automatisch freigestellt.",
                "2. model=standard (30 Schritte, genauer) oder turbo (5 Schritte, schneller, gröber); resolution 380 (schnell) | 768 (ausgewogen) | 1024 (Details, große Datei).",
                "3. color=true überträgt Farben aus den Bildern als Vertex-Farben (braucht alle vier Ansichten); person=true für Menschen.",
                "4. Ergebnis (.glb) mit blender_open in die Blender-Sitzung laden und dort weiterarbeiten.",
                "5. Fertige Modelle aus Dateien oder Links (Sketchfab-Download, .glb/.fbx/.obj …): import_model source=<pfad|url>.",
            ],
            "ansichten_erzeugen": "Fehlende Ansichten mit create_image references=[front] und einem Prompt wie „the same character seen from the left side, same pose, plain white background“.",
            "lizenz": "Hunyuan3D-Lizenz beachten (https://huggingface.co/tencent/Hunyuan3D-2mv/blob/main/LICENSE).",
        ]
    }

    private static func figure() -> [String: Any] {
        [
            "werkzeuge": ["figure_3d", "blender_python (figur.*)"],
            "ablauf": [
                "1. Körper in A-Pose mit offenen Händen und ohne Requisiten: figur.mensch(...) (MPFB, fertig geriggt) oder figure_3d image=<foto einer Person> (Hunyuan3D-Omni mit Posen-Vorgabe a|hand-hoch|arme-hoch, ~7 min, eine MI50).",
                "2. Scans/KI-Meshes: figur.scan_aufraeumen → figur.abgleichen(rig, scan) → figur.gewichte_uebertragen(koerper, scan, rig) oder figur.auto_rig(mesh) (UniRig, CPU, ~3–8 min, sprechende Knochennamen).",
                "3. Kleidung in der A-Pose: figur.kleid_anlegen(kleid, koerper, rig).",
                "4. Posieren: figur.schnell_posieren(True) bei schweren Figuren, dann figur.arm_ik/bein_ik; Handy: figur.handy_griff(rig, 'R'); Bewegung: figur.bvh_laden(datei, rig).",
                "5. figur.porzellan(...) / figur.studio_licht(...), blender_check + blender_look nach jedem Schritt, blender_render zum Schluss, compare_images für Vorher/Nachher.",
            ],
            "alle_bausteine": "blender_python mit result = figur.hilfe() (und helfer.hilfe())",
        ]
    }

    private static func blender() -> [String: Any] {
        [
            "werkzeuge": ["blender_scene", "blender_python", "blender_look", "blender_check", "blender_snapshot", "blender_render",
                          "blender_open", "blender_save", "blender_api", "blender_tools", "blender_session", "sync_files"],
            "ablauf": [
                "1. Bei Projekt-Skripten mit Nachbardateien/Schriften/Assets zuerst sync_files nutzen (oder blender_python script=… with_dir=true).",
                "2. blender_scene lesen und mit blender_python in kleinen Schritten ändern (Variable result für Rückgaben, __file__ und sys.path werden bei Skripten gesetzt, Zustand bleibt erhalten).",
                "3. Nach jedem größeren Schritt blender_check (Zahlen) und blender_look (views=vier, focus auf Details).",
                "4. Vor riskanten Schritten blender_snapshot; bei Verschlechterung restore (nach ~3 erfolglosen Korrekturen zurück statt flicken).",
                "5. blender_render (Cycles auf den MI50; Ergebnis-JSON enthält device, cards, denoiser, samples_reached, setup_s, render_s, kernel_compiled) oder blender_save; compare_images für beschriftete Vergleiche.",
            ],
            "regeln": [
                "Unbekannte API: zuerst blender_api statt raten.",
                "Lange Aufrufe kommen als job_id zurück → get_job wait=45. Reißt die Verbindung ab, holt StudioPortal das Ergebnis selbst ab.",
                "Speichergrenze 40 GB – vor Remesh helfer.groesse_pruefen.",
                "Eigene Hilfsfunktionen mit blender_tools dauerhaft machen; nach Neustart kommen Funktionen und einfache Variablen automatisch zurück.",
            ],
            "bausteine": "result = figur.hilfe() bzw. result = helfer.hilfe()",
        ]
    }

    private static func compare() -> [String: Any] {
        [
            "werkzeug": "compare_images",
            "ablauf": [
                "2–8 Bilder (z. B. file aus blender_render oder create_image) mit labels [\"vorher\", \"nachher\"].",
                "regions für Details, die Zahlen nicht sehen: [{\"name\":\"Kragen\",\"region\":[x0,y0,x1,y1]}] als Anteile 0–1 von oben links.",
                "Über jedem Bild stehen Kamera, Auflösung, Samples, Quelldatei und Dauer aus der Begleitdatei.",
            ],
        ]
    }
}
