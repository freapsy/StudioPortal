# StudioPortal – Aufbau und Bestandteile

Stand: 17.11.2026 · Diese Datei beschreibt, woraus StudioPortal besteht, wie die Teile zusammenspielen und was an
jedem Teil optimiert wurde. Sie ist für Menschen und Agenten gedacht. **Bei jeder Änderung an StudioPortal wird sie
mitgepflegt** (Abschnitt anpassen und unten im Änderungsprotokoll eintragen). Die App zeigt sie unter
*Einstellungen → Übersicht*; auf der Kommandozeile gibt `studioportal info` sie aus.

---

## 1. Was StudioPortal macht

StudioPortal ist eine macOS-App (mit Kommandozeile und MCP-Server für Agenten). Die Rechenarbeit läuft auf dem
Linux-Rechner **bigki** mit drei AMD-MI50-Karten:

| Funktion | Modell / Programm | Karten | Ergebnis |
|---|---|---|---|
| Bilder (Text → Bild, Bearbeiten mit Referenzen) | MiniMax H3 Image (GGUF Q8) mit Qwen3-VL-32B als Textkodierer, eigener sd.cpp-Build | 3 | PNG im Bilder-Ordner |
| Musik | MiniMax Music 3 (`minimaxmusic.cpp`, `mm-synth`) | 1 | MP3/WAV im Musik-Ordner |
| Sprache (TTS & Voice Cloning) | Fish Audio Drama 3 V2 (GGUF Q4_K Experten / FP32 Router / Q8 Backbone) + Qwen3-TTS 1.7B Q8 (`0xShug0/audio.cpp`, HIP `gfx906`) | 1 | WAV im Sprach-Ordner + Live-Stream |
| Telefon-Test (Akquise-Simulator) | 2+1 Split: Qwen3.8 Flash (Strata 2-Karten) + Drama 3 / Qwen3-TTS (1 Karte) + Nemotron 3.5 ASR & Smart Turn v3.2 (CPU) | 2 + 1 | Live-Gespräch (AEC + Soft Barge-In) + Aufzeichnung |
| Video mit Ton | MiniMax H3 Video Turbo4 (GGUF Q6_K) + Audio-VAE | 2 (auf Wunsch 3) | MP4 im Video-Ordner |
| 3D aus 1–4 Ansichten | Hunyuan3D-2mv (Form) + eigene Farbprojektion | 1 + 3 | .blend im 3D-Ordner |
| Figur aus einem Bild | Hunyuan3D-Omni mit Skelett-Vorgabe (A-Pose) | 1 | .glb im 3D-Ordner |
| Blender-Sitzung | Blender 5.3 headless, bleibt zwischen Aufrufen offen | keine (CPU + Intel-Grafik) | Szene, Ansichten, Prüfungen |
| Blender-Render | Cycles auf den MI50 | 1–3 | PNG / MP4 |
| Modell-Import | Sketchfab, Poly Haven, Printables, Blendkit, Dateien → .blend (lokal, Blender auf dem Mac) | – | .blend |

---

## 2. Überblick

```
 MacBook Air (M1)  ──┐                         ┌── bigki (Ubuntu, 3× MI50)
   StudioPortal.app  │   Tailscale (WireGuard)  │     ~/.ssh/authorized_keys: ein Schlüssel je Mac,
   CLI / MCP         ├──── SSH, forced command ─┤     nur "python3 <version>/worker.py"
 Mac mini (M4)  ─────┘                          │     worker.py ── gpu_broker.py (Karten-Warteschlange)
   StudioPortal.app      Sync über SSH/rsync    │        ├─ sd-cli (Bild, Video)   ├─ mm-synth (Musik)
   Zentrale + interne SSD  (Mac mini = Zentrale)  │        ├─ Hunyuan3D-2mv / Omni   └─ Blender (Sitzung, Render)
```

Jeder Auftrag ist **eine** SSH-Verbindung: Die App schickt eine JSON-Zeile, der Worker antwortet mit JSON-Zeilen
(`status`, `waiting`, `progress`, Dateien als `begin`/`data`/`filedone`, `result`, `error`). Schließt die App die
Verbindung, bricht der Worker ab und gibt die Karten frei.

---

## 3. Die Teile im Einzelnen

### 3.1 Macs und Ablage
- **MacBook Air M1**, 8 GB, macOS 27 – Tailscale MAC-1-IP.
- **Mac mini M4**, 16 GB, macOS 27, Tailscale MAC-2-IP. Er ist die Sync-Zentrale. Standardpfade liegen auf der
  internen SSD: Bilder unter `~/Pictures/H3 Studio/Bilder`, Musik unter `~/Music/StudioPortal`, Videos unter
  `~/Movies/StudioPortal` und 3D unter `~/Downloads/3D-Modelle`. Die alte Stori-Voreinstellung wird beim Start ersetzt.
- MacBook: Bilder in `~/Pictures/H3 Studio/Bilder`, 3D in `~/Downloads/3D-Modelle`, Videos in `~/Movies/StudioPortal`.
- **Sync** (`Sync.swift`): MacBook ↔ Mac mini über SSH/rsync, neue Dateien in beide Richtungen, Gelöschtes in den
  Papierkorb, nie überschreiben. Schalter in *Einstellungen → Synchronisation* auf beiden Macs.
- Blender-Ansichten (`blender_look`) landen in `~/Library/Application Support/StudioPortal/Blender-Ansichten`
  (nur die letzten 60) und zusätzlich mit sprechendem Namen in `~/Pictures/H3 Studio/Bilder/Blender-Ansichten/<Tag>/`.

### 3.2 Die App (`src/*.swift`)
- SwiftUI-App, Bundle-ID `local.beispiel.studioportal`, installiert in `~/Applications/StudioPortal.app` auf beiden Macs.
- Bauen: `./build.sh` (Xcode Command Line Tools, Node ≥ 18; Node wird für die Import-Skripte eingebettet).
  Signiert wird mit dem „Apple Development“-Zertifikat dieses Macs (sonst ad-hoc): so behält macOS die Ordner-Freigaben
  (Downloads, SSD) über Updates hinweg; ad-hoc fragt nach jedem Build neu, und bis zur Antwort hängt der Ordnerzugriff.
- **CLI**: `~/.local/bin/studioportal` → die App-Binärdatei. `studioportal help` listet alles.
- **MCP**: `studioportal mcp` (stdio). Werkzeuge u. a. `guide`, `create_image`, `create_music`, `create_speech`, `speech`, `phone`, `create_video`,
  `image_to_3d`, `figure_3d`, `compare_images`, `blender_*`, `sync_files`, `get_job`, `status`, `list_library`, `llm_chat`, `llm`. Lange Aufträge mit `wait=false`.
- **Agenten können alles, was die App kann** (Abgleich 17.11.): jeder Regler der App ist auch ein Parameter
  (Bild: `speed_lora`, `rng`, `flash_attention`, `vae_tiling`, `extra`; Musik: `preset`, `steps`, `lm_cfg`, `dit_cfg`,
  `top_k`, `sound_seed`), und `like=<frühere Datei>` (+ `new_seed`) entspricht „Übernehmen“/„Variieren“.
  **`guide topic=bild|musik|video|3d|figur|blender|vergleich`** (CLI `studioportal guide …`, `Guide.swift`) gibt das
  Bedienwissen der App aus: Ablauf, Prompt-/Songtext-Vorlage, alle Voreinstellungen mit ihren Werten, jeder Regler mit
  „was er tut / was am besten ist“ und die Tipps – erzeugt aus denselben Daten wie die ⓘ-Erklärungen, damit App und
  Agenten nie auseinanderlaufen. Die Werkzeugbeschreibungen und die Anleitung sagen „vorher guide lesen“.
- Wichtige Dateien: `Agent.swift` (CLI + MCP + Anleitung für Agenten), `BlenderVideo.swift` (Video, Blender-Fernsteuerung),
  `FigureRemote.swift` (Omni-Figuren), `H3Backend.swift` (SSH-Verbindung, `runWorker`), `Sync.swift`, `ModelManager.swift`
  (Ordner, Import), `SettingsView.swift`, `Presets.swift` (Voreinstellungs-Kacheln, ⓘ-Erklärungen, Vorher/Jetzt-Diagramm),
  `ImagePresets.swift`/`MusicPresets.swift`/`VideoPresets.swift` (Werte und Texte je Funktion), `BlenderTabView.swift`.
- **Bild, Musik und Video im gleichen Aufbau** (seit 17.11., Vorbild Mobbin: Artlist, OpenAI, Krea, Leonardo;
  `Composer.swift`):
  - In der Mitte steht das Ergebnis (Bild, Song mit Beschreibung/Text oder Video-Player).
  - Unten liegt die **Eingabe**: Prompt, bei Musik zusätzlich der einklappbare Songtext, bei „Bearbeiten“ die
    Referenzbilder. Darunter **Pillen**, die ihre Optionen als Popover öffnen (Voreinstellung, Format/Länge, Anzahl,
    Seed, „Mehr“), und der Startknopf (⌘↩).
  - Rechts steht der **Verlauf** als Feed mit Bild bzw. Poster, Prompt und Info-Chips (Format/MP, Voreinstellung,
    Seed, Dauer, Herkunft). Knöpfe: **Übernehmen** (Prompt und Einstellungen in die Eingabe) und **Variieren**
    (gleiche Einstellungen, neuer Seed, startet sofort).
  - Die Videos speichern dafür auch Schritte und Format in der Begleitdatei.
  - **Oben steht nur etwas, wenn man es auswählt** (seit 17.11. abends): Beim Öffnen und nach „×“/Esc zeigt die Mitte
    eine Start-Ansicht für etwas Neues (drei Schritte, bei Musik Beispiele aus den offiziellen Vorlagen, bei Bild der
    Prompt-Aufbau, bei Video ein Beispiel-Prompt). Ein Klick auf eine Karte rechts öffnet sie, ein zweiter schließt sie.
    Ein neu fertiges Ergebnis wird automatisch geöffnet.
  - Musik: „Mit Gesang / Ohne Gesang“ statt Songtext-Feld + „Instrumental“-Link; „Aufbau einfügen“ setzt die
    Abschnittsmarken. Ohne Gesang hängt die App „No vocals. Purely instrumental.“ erst beim Senden an.
  - Bild: „Zum Vergleich hinzufügen“ (Kartenmenü) sammelt 2–8 Bilder, „Erstellen“ macht dieselbe beschriftete Leiste
    wie `compare_images` und öffnet sie.
- **Musik-Cover** (`MusicCover.swift`), statt überall dasselbe lila Bild: Farbe = Beschreibung (alle Varianten und
  Vollversionen einer Beschreibung haben dieselbe Farbe), Balkenmuster = Melodie-Seed (Vorschau und ihre Vollversion
  sehen gleich aus, Varianten unterscheiden sich), Symbol = mit/ohne Gesang, Etikett = Vorschau/Voll. Titel aus der
  Beschreibung („Indie pop · bedroom pop · 104 BPM“).
- **Flüssiger Wechsel**: Die Bibliothek behält ihre Liste (`LibraryStore`) und lädt nur neu, wenn etwas erstellt,
  synchronisiert oder gelöscht wurde. Vorschaubilder werden abseits des Hauptthreads dekodiert (`AsyncThumbnail`),
  Songlängen gemerkt (vorher wurde bei jedem Öffnen der Musikseite jede Audiodatei geöffnet).
- **3D-Vorschaubilder**: Fehlt einem Modell (.blend oder .glb) die Vorschau, rendert die App sie einmal mit dem
  Blender auf dem Mac (Workbench, 512 px, ~3 s, keine bigki-Rechenzeit; `convert.py --thumbnail-only`), eins nach
  dem anderen mit niedriger Priorität; Fehlschläge werden gemerkt (`preview-failed`). Die Bibliothek zeigt jetzt
  auch .glb-Figuren.
- Bibliothek: Kacheln als feste Quadrate mit Bild-Overlay. Vorher ließ ein `scaledToFill`-Bild das Raster in
  schmalen Fenstern unter die Seitenleiste rutschen. Die Kopfzeile ist jetzt flexibel.
- Jede Funktion hat **Voreinstellungen** (getestete Werte zum Anklicken) und ein **ⓘ** mit Erklärung jedes Reglers.
  Was für die MI50 optimiert wurde (Punkte + gemessene Vorher/Jetzt-Werte), steht **nur** in Einstellungen → Übersicht
  bei der jeweiligen Funktion, nicht in den Werkzeugen.
  Tab **Blender**: zeigt jede Sitzung (auch die der Agenten) live – laufender Aufruf, Speicher, Autosave, letzte Aufrufe,
  Objekte – und holt auf Wunsch eine Vorschau; Rechtsklick auf ein Mesh → „Automatisch riggen“ (UniRig, 3.13).
- **Rechner**-Seite: je Karte Temperatur, Last, Speicher und **wer sie nutzt** („Du (diese App)“, „Agent auf dem Mac mini“,
  bei fremden Programmen Name + Linux-Benutzer, z. B. „Blender · bigki“), die Warteschlange mit Herkunft und alle
  laufenden **Blender-Sitzungen** (wem sie gehören, ob sie gerade arbeiten, Arbeitsspeicher, Objekte). Die Seitenleiste
  zeigt dasselbe kurz. Agenten bekommen es über `status` (`foreign_by`, `blender_sessions`).
- **Bibliothek** lädt Bilder/Musik/Video sofort und die 3D-Modelle danach (deren Ordner liegt auf dem MacBook in
  Downloads, wo macOS den ersten Zugriff bis zur Freigabe anhalten kann).

### 3.3 Verbindung: Tailscale und SSH
- Alle drei Rechner hängen im selben **Tailscale**-Netz; bigki = GPU-SERVER-IP. Mac mini ↔ bigki laufen direkt im LAN.
- Jeder Mac hat einen eigenen Schlüssel `~/.ssh/3d-modelle-bigki`. Auf bigki ist er mit `from="<Tailscale-IP>",restrict,command="…/worker.py"`
  eingetragen: Der Schlüssel kann **nur** den Worker starten, nichts anderes.
- Neue Worker-Version einspielen: `python3 setup_bigki.py --files-only` (legt `~/.local/share/3d-modelle-app/<version>/`
  an und stellt alle StudioPortal-Schlüssel auf die neue Version um; alte Versionsordner bleiben liegen).
- Admin-/Agentenzugang (nicht die App): Mac mini → `ssh -F ~/.ssh/bigki-admin-config bigki-ts`.

### 3.4 bigki – Hardware
| Teil | Wert | Optimierung / Hinweis |
|---|---|---|
| CPU | Intel Core i5-11600K, 6 Kerne / 12 Threads | CPU-Schritte von StudioPortal laufen mit `nice 15` und höchstens 6 Threads, damit Blender und andere Nutzer flüssig bleiben |
| RAM | 61 GB | Blender-Sitzung, Torch-Laden der Modelle |
| SSD | NVMe 1 TB, **~53 % belegt (≈434 GB frei)** (bereinigt 19.11.2026) | Ergebnisse werden zum Mac geholt und auf bigki gelöscht; Aufträge älter als 2 Tage werden entfernt |
| Intel UHD 750 (iGPU) | Rocket Lake | Blender-Sitzung und Vorschauen (`--gpu-backend opengl`, Intel-Vulkan), damit die MI50 frei bleiben |
| **3× AMD Instinct MI50 32 GB** | Vega 20 / gfx906, 60 CUs, HBM2 1 TB/s (gemessen 750–910 GB/s), FP16 ~26 TFLOPS, keine Matrix-Kerne | siehe 3.5 |

### 3.5 Die MI50 – Einzelkarte und Zusammenspiel
- **Leistung**: Profil fest auf **150 W** mit automatischen Takten (`mi50-safe-profile`, `-secondary-`, `-third-`).
  Messungen zeigten: mehr Watt bringt bei diesen Aufgaben kaum etwas (speicherbandbreiten-begrenzt).
- **Kühlung**: eigene Lüfterkurven je Karte über die Mainboard-Lüfter (SYS_FAN2/3/4, `mi50-*-cooling`) mit
  gestaffelter Leistungsdrosselung. Karte an PCI 03:00.0 kühlt schlechter → bekommt bei Video den kleineren Anteil.
- **Schutz**: `mi50-*-thermal-guard` stoppt Experimente bei 91 °C und schaltet bei 95 °C Hotspot den PC aus.
  StudioPortal selbst: Karte nur unter **92 °C** vergeben, Musik und Video starten erst unter **65 °C**.
- **Anbindung**: Die dritte Karte hängt per **OCuLink**, fest auf PCIe Gen3 (`mi50-oculink-gen3`, Gen4 zeigte
  Empfangsfehler). Keine Infinity-Fabric-Brücke → Karten tauschen Daten nur über PCIe aus.
  Deshalb verteilt StudioPortal Arbeit lieber **parallel auf unabhängige Teile** statt ein Modell eng über Karten zu koppeln:
  - Bild: ein Prozess über 3 Karten (Modellteile verteilt, VAE-Tiling).
  - 3D: Form auf 1 Karte, Oberfläche (Decoding in Blöcken) auf 3 Karten parallel.
  - Video: 2 Karten, Modell aufgeteilt (heiße Karte kleinerer Anteil), die dritte bleibt für andere frei.
  - Blender-Render: 2 Cycles-Prozesse je Karte, jeder rendert eigene Bilder/Kameras.
  - Musik, Omni-Figur: je 1 Karte.
- **ROCm**: eigener Build für gfx906 in `~/.local/opt/rocm-gfx906-7.14` (offiziell nicht mehr unterstützt).
- Tiefe Hardware-Details, Messungen und Experimente (LLM-Decoding, Bandbreiten, Kernelstarts): `~/mi50-phase0/GEMEINSAM/`
  auf bigki (`01_MI50_Architektur_und_Grenzen.md`, `02_Forschungsrichtungen.md`, `B_Messungen/`).

### 3.6 bigki – Linux
- Ubuntu 26.04.1 LTS, Kernel 7.0. Systemd-Dienste für die Karten: `mi50-cooling`, `mi50-secondary-cooling`,
  `mi50-third-cooling`, `mi50-*-safe-profile`, `mi50-*-thermal-guard`, `mi50-oculink-gen3`. **StudioPortal ändert keine
  dieser Dienste und keine Systemeinstellungen.**
- Gemeinsame GPU-Sperren anderer Programme: `~/mi50-phase0/mi50-experiment.lock`, `~/.local/share/paiton/gpu-coordination/gpu.lock`.

### 3.7 Worker und Karten-Broker (`src/bigki_worker.py`, `src/gpu_broker.py`)
- Liegen versioniert in `~/.local/share/3d-modelle-app/<version>/` (Version = Hash der Dateien).
- **Broker**: vergibt einzelne Karten streng in Startreihenfolge; startet bei Bedarf, beendet sich nach 5 min Leerlauf.
  Regeln: fremde Prozesse werden **nie** angefasst; taucht ein fremder Prozess (z. B. Blender-Render) auf einer Karte auf,
  wird nur unser Prozess dort gestoppt und später automatisch neu gestartet. Hotspot ≥ 92 °C oder unlesbarer Sensor
  stoppt unseren Prozess. Musik hält zusätzlich die paiton-Sperre.
- **Wer nutzt was**: Der Broker liest für fremde Prozesse auf einer Karte Programmname und Benutzer aus `/proc`
  (`foreign_by`, z. B. „Blender · bigki“, „ComfyUI · paiton“); der Worker meldet laufende Blender-Sitzungen
  (`sessions`: Name, RAM, aktueller Befehl, letzter Aufruf, Objekte). Beides kommt mit `operation: machine`.
- **Worker**: prüft jede Anfrage (Größen, Pfade, erlaubte Werte), legt Aufträge in eigenen Ordnern an, schickt
  Ergebnisse zurück und räumt auf.
- **Verbindungsabbruch / Abbrechen**: Schließt die App die Verbindung ohne Absicht (Tailscale-Hänger), stoppt der
  Worker den Auftrag. Ausnahme Blender-Render: Er trägt einen Abholschein (`ticket`), rendert weiter und legt das
  Ergebnis in `blender/<sitzung>/abholung/<ticket>/` ab (12 h); die App holt es mit `abholen` und meldet `abgeholt`.
  Echtes Abbrechen schickt ausdrücklich `abbrechen` über stdin und stoppt auch einen abgekoppelten Render.
  Lange Aufträge halten die SSH-Verbindung bis ~6 min Funkstille (sonst 90 s).
- **Fehlerprotokolle**: Figur-Aufträge schreiben `figur/jobs/<auftrag>/omni.log` (bleibt bei Fehlern 2 Tage).

### 3.8 Modelle und Programme auf bigki
| Zweck | Ort |
|---|---|
| H3 Image | `~/h3-image/models/`, Programm `~/sdcpp-h3image/…/sd-cli` |
| H3 Video | `~/sdcpp-mi50/models/`, Audio-VAE in `~/.local/share/paiton/minimax-h3/` |
| Musik | `~/minimaxmusic.cpp` (`build-hip906/mm-synth`), Ausgaben `~/music3/output/studioportal` |
| Hunyuan3D-2mv | `~/hunyuan3d-2mv` (eigene venv, Torch 2.11 + ROCm 7.1 aus `~/music3/.venv`) |
| Figuren | `~/.local/share/3d-modelle-app/figur/`: `omni/` (Code), `hf/` (Gewichte: Omni, DINOv2, UniRig), `omni-venv` (nutzt Torch der 2mv-venv nur lesend), `unirig/` + `unirig-venv` (CPU) |
| Python-Zusatz für Blender | `~/.local/share/3d-modelle-app/pylib/py313` (scipy, libigl, robust_laplacian) |
| Blender | 5.3-Build unter `~/blender-r9700/…`, für StudioPortal verlinkt als `~/.local/share/3d-modelle-app/bin/studioportal-blender`; Render über `~/blender-mi50` |

### 3.9 Blender-Sitzung (`src/blender_session.py`, `src/studio_figur.py`, `src/studio_helfer.py`)
- **Was es tut**: eine dauernd offene Blender-5.3-Sitzung ohne Bildschirm, die Agenten (und die App) Schritt für
  Schritt bedienen: Python ausführen, ansehen, prüfen, rendern. Eine Sitzung je Mac (`macbook`, `mac-mini`), Ordner
  `~/.local/share/3d-modelle-app/blender/<name>/`.
- **Weg**: Agent/App → `studioportal` (MCP/CLI) → SSH → Worker → Unix-Socket → Blender 5.3 (CPU + **Intel-Grafik**)
  → Render: Cycles (HIP) auf den **MI50**
- **Normal**: Blender läuft mit Fenster an einem Rechner; ein Skript wird einmal ausgeführt und Blender beendet sich.
  Headless greift Blender 5.3 über Vulkan automatisch die erste GPU.
- **Auf der MI50 angepasst**:
  - Die Sitzung zeichnet über OpenGL auf der Intel-iGPU (`--gpu-backend opengl`, Intel-Vulkan-Treiber erzwungen) –
    sonst belegt jeder Blender-Prozess ~1,2 GB auf MI50 Karte 0 und blockiert den Karten-Broker.
  - Endgültige Renders laufen als eigene Prozesse mit Cycles/HIP (`~/blender-mi50`) über den Broker: **zwei Blender je
    Karte**, jede Kamera/Bildfolge parallel; bei Verbindungsabbruch rendert bigki weiter (Abholschein).
  - Speicherwächter (40 GB von 61 GB): stoppt die Sitzung mit Grund (`absturz.json`) statt bigki einzufrieren.
  - Automatisches Speichern nach jedem Aufruf (sobald 1,5 s Ruhe ist), damit ein Absturz höchstens einen Aufruf kostet.
  - `status.json`/`laeuft.json`: die App sieht ohne zu warten, was gerade läuft (Tab **Blender**).
  - **Kein Auftrag geht verloren**: Jeder Sitzungsaufruf (python, look, check, scene, tools, snapshot …) trägt wie der
    Render einen Abholschein. Reißt die SSH-Verbindung ab, wartet der Worker weiter auf die Sitzung, legt die Antwort
    (mit Bild) in `abholung/<ticket>/` ab und die App holt sie automatisch (bis 10 min Versuche, 12 h liegen lassen;
    Agenten: `blender_session action=abholen ticket=…`). Lange Aufrufe melden alle 60 s „Blender arbeitet noch“.
  - **Hängende Vorschau**: Läuft `look` länger als 240 s, beendet der Worker genau diesen Sitzungsprozess (Prüfung über
    `/proc/<pid>/cmdline`), schreibt den Grund in `absturz.json` und meldet ihn; der nächste Aufruf startet neu. Vor jedem
    `look` mit ungespeicherten Änderungen wird zuerst gespeichert, damit dabei nichts verloren geht. **Echter Test 17.11.**
  (`render_pre`-Handler, der 400 s schläft): nach 245 s beendet, Meldung an den Aufrufer, nächster Aufruf mit Grund im
  `hinweis` und allen Objekten bis vor der Vorschau.
  - **Echter Verbindungsabbruch** (SSH nach 10 s hart getrennt, Aufruf mit 45 s Rechenzeit): Die App verbindet sich
    selbst neu und holt das Ergebnis ab, insgesamt 47 s.
  - **Neustart ohne Gedächtnisverlust**: Funktionen, Klassen und Imports aus erfolgreichen `blender_python`-Aufrufen
    (`sitzung_defs.json`, je Name die neueste Fassung) und einfache Variablen (Zahlen, Text, Listen, Dicts, Vektoren,
    Matrizen, Blender-Objekte/Pose-Knochen per Name; `sitzung_variablen.json`, beim Speichern geschrieben) werden nach
    einem Neustart automatisch wiederhergestellt; der `hinweis` nennt, was zurück ist und was nicht ging. `reset` löscht beides.
  - **Neustartgrund**: Beim regulären Ende schreibt die Sitzung `ende.json` (quit, 30 min Leerlauf, Stoppsignal). Der
    `hinweis` nach dem Neustart nennt den echten Grund. Fehlt die Datei und gibt es keinen Absturzbericht, steht dort
    „von außen beendet (z. B. Neustart von bigki oder kill)“.
- **Werkzeuge**: `python` (mit `LOG`-Zeilen, `persist`, `script` = Datei auf dem Mac oder `bigki:~/…`; dauert ein
  Aufruf > 50 s, kommt eine `job_id` → `get_job wait=45`), `scene` (warnt bei Objekten > 10 m), `look` (Raster,
  Fokus, Einfärben, Vorlage daneben, Zoom/Ausschnitt; meldet `im_bild`, warnt bei „nur im Viewport ausgeblendet“ und bei
  identischem Bild; Kopie in `Bilder/Blender-Ansichten/<Tag>/`), `check` (lose Teile zählen/löschen, Löcher, Dicke,
  Schichten, Boden, Kontakt, **Ausreißer-Punkte**), `snapshot`/`restore`, `tools` (`werkzeuge.py` + ganze
  Skriptdateien als `werkzeuge/<name>.py`, bei jedem Start geladen), `open`/`save`, `render`, `status` (sofort).
- **Bausteine**: `helfer.*` (kamera, punkte, glaetten, **groesse_pruefen**, remesh mit Größenprüfung, dezimieren) und
  `figur.*` (mensch/MPFB, porzellan, studio_licht, scan_aufraeumen, abgleichen, gewichte_uebertragen, arm_ik/bein_ik,
  objekt_in_hand, hand_greifen, **handy_griff**, anhaengen, aufstellen, kleid_anlegen, kleid_simulieren,
  **schnell_posieren**, **bvh_laden**, auto_rig). Python-Pakete: numpy, scipy,
  igl, robust_laplacian (`pylib/py313`).
- Neu nach Agenten-Rückmeldung (17.11.):
  - `gewichte_uebertragen(…, modus='naechster')`: Gewichte direkt vom nächsten Hautpunkt (baryzentrisch, ohne
    Auffüllen) – ruhig auf dichten Netzen; Standard in `kleid_anlegen` (das robuste Auffüllen ließ Kleider reißen).
    Gewichte werden gebündelt geschrieben (1,2 Mio. Punkte in 6,6 s).
  - `handy_griff(rig, 'R')`: Handy hochkant – Rücken auf der Handfläche, vier Finger um die ferne Kante, Daumen an der
    nahen Kante (Vorlage: Skript `griff_pose.py` des Agenten); Abstandsfeld eines abgerundeten Quaders, Daumen per
    Rastersuche. Test: 28 s, kleinster Abstand Hand↔Handy 0,8 mm.
  - `schnell_posieren(True/False)`: nimmt schwere, geriggte Meshes aus der Auswertung und zeigt einen leichten
    Stellvertreter (~60 000 Punkte, gleiche Gewichte) – Test 1,2 Mio. Punkte mit Corrective Smooth: 10 Knochenänderungen
    2,5 s → 0,03 s. Zustand steht in der Szene und übersteht Neustarts.
  - `bvh_laden(datei, rig)`: BVH (CMU u. a.) oder Mixamo-FBX → MPFB-Skelett. Namen werden zugeordnet (Mixamo/BVH-Standard,
    eigene per `zuordnung`). Gliedmaßen folgen der Knochenrichtung der Quelle (Schwenk Ruhe-Richtung Quelle → Ziel;
    ein T-Pose-Bild der Quelle ergibt also eine T-Pose). Rumpfknochen (root, spine, neck, head) bekommen **keinen**
    Schwenk: Der Hüftknochen aus dem BVH-Import zeigt je nach Proportionen nach unten, und der Schwenk hatte das Becken
    um 180° gedreht (Codex-Test: Kopf 55 cm unter der Hüfte). Schwenks über 100° werden verworfen (`ohne_ausrichtung`).
    Knochen mit verworfenem Schwenk (z. B. CMU-Hände, Länge 0) übernehmen die Korrektur des Elternknochens
    (`ausrichtung_vom_elternknochen`). Außerdem werden die Blickrichtung angeglichen und die Hüftbewegung auf die
    Beinlänge skaliert. **Hüfthöhe** über den Knöcheln des Clips (nicht der Ruhepose – beim CMU-BVH hängt das Ruhe-Skelett
    unter einer Wurzel im Ursprung, die Figur schwebte sonst ~1 m hoch); waagerecht startet die Figur an ihrem Platz.
    **Bodenkontakt**: Eine Gerade durch die tiefsten Punkte des Clips gleicht unterschiedliche Bein-Proportionen und
    schiefe Mocap-Böden aus. Die Schlüssel gehen direkt in die F-Kurven. Die Antwort enthält `pruefung`:
    `kopf_ueber_huefte_cm`, `boden_abstand_cm`, `boden_korrigiert_cm`, `boden_neigung_ausgeglichen_cm`, `weg_m`.
    Test 17.11. mit CMU 02_01 (Gehen, 344 Bilder @120 fps): 3,15 m geradeaus in Blickrichtung (0,6° Abweichung),
    Hüfte 0,89–0,90 m, Knöchel im Standbein 7 cm, Boden −6,4 cm und Neigung 5,3 cm ausgeglichen, Hände natürlich.
- Rezept für Figuren: **A-Pose → aufräumen → riggen/Gewichte → Kleidung anlegen → posieren → Material/Licht**, nach jedem
  Schritt `check` + `look`, vor riskanten Schritten `snapshot`.
- **Vergleichsleiste** (`compare_images` / `studioportal vergleich`, `src/Compare.swift`, läuft auf dem Mac):
  - 2–8 Bilder nebeneinander. Über jedem stehen Titel und Fakten aus der Begleitdatei (Kamera, Auflösung, Samples,
    Quelldatei, Dauer).
  - `regions` erzeugt gleiche Detailausschnitte aus allen Bildern in voller Auflösung als weitere Zeilen und markiert
    sie gelb im ganzen Bild.
  - Ablage: `Bilder/Vergleiche/<Tag>/`.
  - Damit die Fakten da sind, liefert `render` jetzt Kamera, Auflösung, Samples und Quelldatei an die Begleit-JSON.
- **Gemessen**: Vorschau belegt 0 GB auf den MI50 (vorher 1,2 GB je Prozess); Render nach hartem SSH-Abbruch wurde nach
  weiteren 468 s abgeholt.

### 3.10 Bilder
- **Was es tut**: Text → Bild (1–16 MP, bis 4 Bilder) und Bearbeiten mit bis zu 16 Referenzbildern.
- **Weg**: App/Agent → SSH → Worker → Broker (alle 3 Karten) → **sd-cli** (stable-diffusion.cpp, eigener
  gfx906-Build) → MiniMax H3 Image Q8 → PNG zurück zum Mac → `~/Pictures/H3 Studio/Bilder`
- **Normal**: MiniMax H3 Image läuft in ComfyUI/PyTorch auf einer großen NVIDIA-Karte (CUDA) mit 6 Schritten, CFG 1.
- **Auf der MI50 angepasst**:
  - Statt PyTorch läuft **stable-diffusion.cpp** (ggml), mit HIP für gfx906 gebaut (`~/sdcpp-h3image`, Compiler und
    Bibliotheken aus dem eigenen ROCm-7.14-Build – AMD unterstützt gfx906 offiziell nicht mehr).
  - Das Bildmodell passt nicht auf eine 32-GB-Karte: es wird **schichtweise auf alle drei MI50** verteilt
    (`--split-mode layer`), die VAE liegt auf Karte 2, das Textmodell Qwen3-VL-32B wird bei Bedarf **von der SSD
    gestreamt** (`--params-backend te=disk`) statt dauerhaft Grafikspeicher zu belegen.
  - Flash-Attention im gfx906-Build (`--diffusion-fa`), VAE in Kacheln (ab ~2 MP sonst zu wenig Speicher), Zufall auf der
    CPU (`--rng cpu`: gleicher Seed = gleiches Bild).
  - Die Karten tauschen nur über PCIe aus (keine Infinity-Fabric-Brücke) – darum Schichten statt enger Kopplung.
- **Voreinstellungen** (Testreihe 17.11., gleicher Prompt/Seed): Schnell 1 MP, Foto 4 MP (1:1), Porträt 4 MP 3:4 mit
  `lcm`+`simple`+Rauschplan (natürliche Haut), Landschaft 4 MP 16:9, Maximal 16 MP (native Größe), Bearbeiten 4 MP im Format von
  Picture 1. ⓘ erklärt jeden Regler. Ergebnis der Tests: 6 Schritte/CFG 1/euler/H3-Zeitplan sind richtig; mehr Pixel
  bringen echte Poren und Haare; ein langer Kamera-Prompt steuert Ort, Licht und Kleidung.
- **Gemessen**: 1 MP 75 s, 4 MP 136 s (4× Pixel für 1,8× Zeit), 16 MP ~10¾ min Rechnen (~12 min mit Laden).
- **Internet-Abgleich** (17.11.; ComfyUI-Doku/-Wiki, Unsloth, Template-Gist, Pixelailabs): übereinstimmend 6 Schritte, CFG 1,
  euler + H3-Zeitplan, `--rng cpu`, ab ~4 MP (darunter leiden Gesichter/Zähne), bestens um 16 MP, Prompt 80–150 Wörter,
  4–8 Seeds pro Prompt; beim Bearbeiten nie Seed+Größe des Ausgangsbilds. Deshalb: „Schnell“ nur noch zum Prüfen des
  Bildaufbaus, „Bearbeiten“ jetzt 4 MP. Test 16 MP euler vs. lcm (gleicher Seed, je ~10¾ min): euler rauer und
  überschärft mit allen Sommersprossen, lcm klarere Augen und natürlichere Haut – „Porträt“ bleibt lcm, „Maximal“ euler.
- **Speed-LoRA** (pDMD 2 Schritte, Apache-2.0, `akhaliq/minimax-h3-image-pdmd-2step`, ComfyUI-Datei): liegt als
  `~/.local/share/3d-modelle-app/loras/pdmd2fix.safetensors` auf bigki (Metadaten-Eintrag „alpha“ entfernt, den sd.cpp nicht
  lesen kann; die Alpha-Tensoren bleiben). Die App setzt `<lora:pdmd2fix:1>` vor den Prompt und `--steps 2 --scheduler simple
  --flow-shift 12 --lora-model-dir …`. Voreinstellung „Schnell“: 4 MP in 76 s statt 136 s (Rechnen 50 statt 110 s), sauber,
  Haut etwas glatter. Bei 16 MP (272 s statt 640 s) Mosaik-Artefakte → App erlaubt sie nur bis ~5 MP. Ohne LoRA sind 2 Schritte
  verschwommen. Andere LoRAs: fast alle für H3 Video, nicht für H3 Image.
- **Porträt-Rezept** (Pixelailabs, getestet 16 MP, gleicher Seed, je ~10¾ min): lcm + simple + `--extra-sample-args noise_scale_start=1.1,noise_scale_end=0.9,noise_clip_std=0`
  (lcm-Rauschstärke fällt über die Schritte von 1,1 auf 0,9). Gegenüber lcm allein feinere Poren und mehr Struktur an
  Lippen/Zähnen, weiterhin natürlicher als euler → in „Porträt“ eingestellt. Für Qualität (nicht Tempo) bleibt die Speed-LoRA
  nur in „Schnell“; alle anderen Voreinstellungen rechnen mit 6 Schritten.

### 3.11 Musik
- **Was es tut**: Song mit Gesang (oder instrumental) aus Beschreibung + Songtext (MiniMax Music 3), MP3/WAV.
- **Weg**: App/Agent → SSH → Worker → Broker (1 Karte je Variante) → **mm-synth** (minimaxmusic.cpp, gfx906-Build)
  → Sprachmodell schreibt Audio-Codes → DiT malt den Klang in 8-s-Fenstern → MP3 + Replay-Datei zum Mac
- **Normal**: MiniMax Music 3 läuft mit PyTorch/Diffusers auf einer CUDA-Karte (~22 GB), ein Song nach dem anderen.
- **Auf der MI50 angepasst**:
  - **minimaxmusic.cpp** (ggml/C++) statt PyTorch, mit HIP für gfx906 gebaut (`build-hip906`, ROCm-7.14-Umgebung).
  - Ein Song passt auf eine Karte → **bis zu drei Varianten gleichzeitig** auf den drei MI50 (Seed, Seed+1, Seed+2).
  - **Zweistufig mit gespeicherten Audio-Codes**: Skizzen mit 8 Diffusionsschritten, „In voller Qualität“ rechnet nur
    den Klang mit 30 Schritten neu – Melodie und Aufbau bleiben gleich, das Sprachmodell läuft nicht noch einmal.
  - Start erst unter 65 °C (lange Songs halten die Karte minutenlang voll), hält die gemeinsame paiton-GPU-Sperre.
- **Voreinstellungen**: Skizzen (3 × 8 Schritte), Song fertig (30), Klare Stimme (DiT-CFG 1,5), Instrumental
  (`[intro] [instrumental] [solo] [instrumental] [outro]` + „No vocals“), Mehr Abwechslung (Top-K 100, LM-CFG 1,5);
  Längen-Vorschlag ≈ 6 s je gesungener Zeile. Werte aus der Modellkarte, dem ComfyUI-Knoten und dem Fuser-Guide.
- **Gemessen** (60-s-Song, 17.11.): eine Skizze 203 s, drei Skizzen parallel 284 s (nacheinander wären es ~610 s),
  „In voller Qualität“ 379 s (ohne erneutes Sprachmodell; komplett neu wären es geschätzt ~480 s).

### 3.12 Video
- **Was es tut**: Text → Video mit Ton (MiniMax H3 Video Turbo4, 24 fps, bis ~9 s).
- **Weg**: App/Agent → SSH → Worker → Broker (2 kühlste Karten) → **sd-cli** Video-Build (`~/sdcpp-mi50`) mit
  Token-Aufteilung → AVI → ffmpeg (H.264/AAC) → MP4 zum Mac
- **Normal**: H3 Video läuft in ComfyUI/LightX2V auf einer großen CUDA-Karte; Turbo4 = 4 Schritte, euler, simple,
  Shift 6, CFG 1 (Empfehlung lightx2v).
- **Auf der MI50 angepasst**:
  - Eigener sd.cpp-Video-Build für gfx906 mit **Token-Aufteilung** (`SD_H3_TOKEN_SPLIT`): jede Karte rechnet einen Teil
    der Bild-Tokens, pro Schritt werden Zwischenergebnisse über PCIe getauscht.
  - Die heißere Karte (PCI 03:00) bekommt nur **42,5 %** der Tokens, damit beide Karten gleichzeitig fertig sind.
  - Zwei Karten statt drei: drei sind kaum schneller (~25 s Austausch je Schritt), die dritte bleibt frei.
  - Textmodell von der SSD (`te=disk`), VAE auf beide Karten verteilt, Start unter 65 °C, Zufall auf der CPU.
  - Sampler-Werte fest auf die Turbo4-Empfehlung; Länge rastet auf das 17n+5-Raster ein (56/124/192/226 Bilder);
    **6 Schritte als Standard** (4 nur für Entwürfe).
- **Gemessen (17.11., 124 Bilder, gleicher Seed)**: 4 Schritte 280 s, 6 Schritte 462 s (+65 %). 6 Schritte sind sichtbar
  schärfer (Gesichter, Hände, Stoff), deshalb Standard – die Qualität geht vor.
- **Voreinstellungen**: Entwurf (2 s, 4 Schritte), Clip 5 s (6), Schnell 5 s (4), Hochkant 9:16, HD 1280×704, Lang 8 s.

### 3.13 3D und Figuren
- **Was es tut**: 3D-Modell aus 1–4 Ansichten (Hunyuan3D-2mv) und realistische Figur aus **einem** Bild in A-Pose
  (Hunyuan3D-Omni mit Skelett-Vorgabe), danach Weiterarbeit in der Blender-Sitzung.
- **Weg**: App/Agent → SSH → Worker → rembg (CPU) → Form auf 1 Karte (PyTorch/ROCm) → Oberfläche (Volumen →
  Marching Cubes) → GLB zum Mac → Blender
- **Normal**: Hunyuan3D läuft mit PyTorch auf CUDA, nutzt Flash-Attention und CUDA-Erweiterungen (Textur-Rasterizer).
- **Auf der MI50 angepasst**:
  - PyTorch 2.11 mit ROCm 7.1 in eigener venv; rocBLAS mit den gfx906-Kernelbibliotheken des eigenen ROCm-Builds.
  - 2mv: Form auf 1 Karte, das Dekodieren der Oberfläche **in Blöcken parallel auf drei Karten**; Farben werden ohne
    CUDA-Rasterizer per eigener Projektion auf der CPU übertragen.
  - Omni: gfx906 hat keinen Flash-/Mem-Efficient-Attention-Kernel → Omni wird auf den Mathe-Pfad umgebogen, und die
    Oberfläche wird mit **FlashVDM** dekodiert (nur Voxel nahe der Oberfläche statt des ganzen 512³-Gitters, Blöcke
    à 20 000 Punkte).
  - Freistellen mit rembg auf der CPU, Schwebeteile und kaputte Flächen werden entfernt; Fehlerprotokoll je Auftrag.
- **Gemessen**: Omni-Figur 413 s statt Abbruch nach > 30 min (volles Gitter mit Mathe-Attention).
- **In der App**: Tab „Bild zu 3D“ → Art „Figur mit Pose“: ein Foto, Pose A-Pose / Hand hoch / Arme hoch, derselbe
  Aufruf wie `figure_3d`; eigener Verlauf der Figuren (.glb).
- **Automatisch riggen (UniRig)**: `figur.auto_rig(objekt)` in der Blender-Sitzung (oder Rechtsklick im Blender-Tab) –
  exportiert das Mesh als GLB, UniRig erzeugt Skelett (~8 min) und Gewichte (~1 min) **auf der CPU**, Ergebnis kommt als
  `<objekt>_Rig` + `<objekt>_rigged` zurück (Ort/Größe bleiben, Materialien übernommen, Original ausgeblendet).
  Test 17.11.: 2-Mio-Vertex-Figur, 52 Knochen, 491 s gesamt.
  - **Sprechende Namen**: `auto_rig` benennt die Knochen danach wie bei Rigify (`figur.knochen_benennen(rig)` auch
    einzeln): hips, spine…, neck, head, shoulder/upper_arm/forearm/hand.L|R, thumb…pinky.01.L,
    pelvis/thigh/shin/foot/toe.L|R, tail.NN, head_extra.NN.
  - Die Zuordnung kommt aus Aufbau und Lage: Die Wirbelsäule ist die Kette nach oben. Ellbogen und Knie liegen auf
    halber Strecke zum Handgelenk bzw. Knöchel, Zwischenknochen bekommen .001. Finger werden von vorn (Daumen) nach
    hinten sortiert, die Blickrichtung kommt aus den Füßen.
  - Die Vertexgruppen werden mit umbenannt.
  - Test am anonymisierten MPFB-Rig (163 Knochen): Körper, Arme, Beine und alle Finger richtig. Gesichtsknochen
    landen in head_extra.
  Angepasst für bigki: venv `figur/unirig-venv` mit eigenen Shims (`figur/unirig-shims`: `flash_attn` → SDPA je Segment),
  spconv rechnet den Bias auf der CPU nach der Faltung, open3d-cpu statt pyrender/EGL, Konfigurationen
  `cpu_skeleton`/`cpu_skin`. Belegt keine MI50.

---

### 3.14 Sprachmodell (LLM-Chat, `src/LLM.swift`, Worker `operation: llm`)
- **Qwen3.8 Flash Next** (OrcaRouter IQ3_M) mit **Strata** auf allen drei MI50 – die schon vorhandene, für die MI50
  optimierte Installation des Nutzers (Beschreibung und Messverlauf: `~/llm/MI50-Strata/README.md` auf bigki).
  Profil `~/llm/strata-v0.2.7-mi50/strata-orca-iq3_m-mi50.json` (enthält den API-Schlüssel, nie ausgeben), Start über
  `~/Downloads/strata/START-MI50.sh --start` (Systemd-Unit `mi50-strata.service`, Wächter und Kühlung inklusive),
  OpenAI-kompatibel auf Port 8080.
- Der Worker startet Strata **bei Bedarf**: Er holt sich alle drei Karten über die Broker-Warteschlange (wartet also
  auf laufende Bild-/Musik-/Fremdjobs) und **behält sie, bis Strata antwortet** (~75 s), damit kein Auftrag in den Start
  rutscht. Die gemeinsame MI50-Sperre nimmt eine `llm`-Belegung nicht – die holt sich Stratas Starter
  (`strata-guarded.py`) selbst und bricht sonst ab. Läuft Strata, sieht der Broker es auf allen drei Karten (fremder
  Prozess „Sprachmodell (Strata)“ + MI50-Sperre) und vergibt keine Karte: Bild/Musik/Video warten bis zum Stopp. Marker
  `llm/started-by-studioportal`; ein abgekoppelter Wächter (`worker.py --llm-idle-watch`) stoppt Strata nach
  **20 min ohne Anfrage**, aber nur, wenn StudioPortal es gestartet hat. Der Wächter berücksichtigt laufende,
  wartende und abgeschlossene Anfragen aller Clients anhand von Stratas `/metrics/prometheus`. Ein von Hand/Desktop gestartetes Strata stoppt
  `stop` nur mit `force`.
- Chat streamt Tokens (alle ~80 ms gebündelt) sowie bei aktivem Denken die Gedanken (`reasoning`); das Ergebnis enthält
  `tokens_per_second`, `prompt_tokens_per_second` (aus den Server-Timings), `completion_tokens`, `first_token_s`,
  `seconds`, `reasoning` und `reasoning_effort`. Die App zeigt Geschwindigkeit (inkl. Prompt-t/s) und Denkstufe unter
  jeder Antwort sowie den Gedankengang einklappbar über der Antwort.
- **Denkstufen (`reasoning_effort` / `thinking`)**: Qwen3.8 Flash Next unterstützt über Strata vier Stufen:
  `none` (Aus, Standard – direkte Antwort), `low` (Niedrig), `medium` (Mittel, auch bei `thinking=true`) und
  `high` (Hoch / `xhigh`). Wählbar im Composer der macOS- und iPhone-App, per CLI (`--thinking none|low|medium|high`)
  und per MCP (`reasoning_effort`).
- Gemessen 20.11.2026 über StudioPortal (Strata v0.2.16 `mtp1`, `STRATA_MTP_STAGE=1`, Split `17,33`): Code ~149 t/s
  (Benchmark 140,0 t/s), deutsche Prosa ~101 t/s (Benchmark 89,7 t/s), 10k-Prompt ~931 t/s.
- **Live-Anzeige** (Mac-Chat, `src/StrataLive.swift`): Solange eine Antwort läuft, fragt die App jede Sekunde Stratas `GET /metrics`
  (LAN, sonst Tailscale; Schlüssel aus `~/.pi/agent/models.json`) und zeigt über dem Eingabefeld „Liest Prompt · 19,1k · 17,9k aus dem
  Zwischenspeicher · 930 t/s“ bzw. „Schreibt · 116 t/s · 300 Token“; die Kontextzahl läuft mit. Pi/PhotoCraft-Antworten bekommen am Ende das
  Tempo des letzten Schritts angehängt. Ohne Schlüssel oder Verbindung fehlt die Zeile einfach.
- **Kontext und Auto-Compact** (Mac-Chat): Strata hat **262.144 Token** (`--max-context`, `llm status` meldet `context`) –
  die nativ trainierte Länge von Qwen3.8 Flash Next (kein YaRN). Seit 20.11.2026 (vorher 163.840, aus der Zwei-Karten-Zeit;
  Backup `strata-orca-iq3_m-mi50.json.bak-20261120-vor262k`). Strata belegt den ganzen KV-Speicher beim Start (int8,
  12 QSA-Schichten): gemessen VRAM frei 8,7 → 8,2 GB, weiter alle 24.576 Experten im Cache, Code ~129 t/s.
  Über dem Eingabefeld steht „Kontext 52k / 262k · Compact ab 246k“; ein Klick darauf wählt, **ab wann automatisch
  zusammengefasst wird** (kurz vor der Grenze oder ab 32k … 240k, UserDefaults `llmCompactAt`, gilt für Chat und Pi;
  an Pi gehen Kontextfenster und `reserveTokens = Fenster − Grenze` beim Start der Sitzung, ändern beendet die laufende
  Pi-Sitzung). Im selben Menü wählt „Bei Auto-Compact wörtlich behalten“ 20k (Standard), 30k oder 40k
  (`llmCompactKeep`). Die Änderung startet Pi beim nächsten Auftrag mit dem neuen `keepRecentTokens`.
  Bei frühem Auto-Compact gilt höchstens ein Drittel der Grenze, und das Menü zeigt den wirksamen Wert.
  Orange ab 20k vor der Grenze. Strata hält den laufenden Chat im Zwischenspeicher
  (gemessen: 13.700 Token Verlauf → Folgefrage liest 20 neue Token, 0,4 s statt 14 s; bis zu 4 Unterhaltungen geparkt),
  ein langer Verlauf kostet also kaum Zeit. Erst an der gewählten Grenze (Standard: 16k vor Schluss, ~246k) fasst Qwen die älteren
  Nachrichten zusammen. Die gewählte Menge bleibt ungefähr wörtlich (Mac-Chat und Pis eingebaute Compaction,
  gemeinsame Obergrenze in `src/ChatCompaction.swift`). Das kostet einmal ein volles Neulesen (~2,5 min). Die
  Zusammenfassung wird mit gespeicherten Chats gesichert. Das iPhone und CLI/MCP schicken den Verlauf weiter ungekürzt.
- CLI `studioportal llm "Frage" [--thinking none|low|medium|high]` bzw. `llm status|start|stop`; MCP `llm_chat`, `llm`.

#### Pi und PhotoCraft im Mac-Chat
- **Pi** aktiviert den Coding-Modus im LLM-Chat. Bei ausgeschaltetem PhotoCraft stehen `read`, `write`, `edit`,
  `bash`, `ls`, `find` und `grep` zur Verfügung. Projektdateien und Befehle verwenden den ausgewählten Arbeitsordner
  als Startverzeichnis. Lokale Laufzeiten wie `python3` können Skripte und Tests ausführen. Eine einzeln ausgewählte
  Datei wird als Kopie bereitgestellt. Ohne Projektordner schreibt Pi Ergebnisse unter `Pi-Ergebnisse`. Die
  vorhandene Dateifreigabe und optional die Websuche gelten auch für Pi. Der Pi-Modus wird mit gespeicherten Chats
  wiederhergestellt.
- **Websuche:** Fehlen passende Treffer, soll Pi den Suchbegriff ändern oder die Lücke melden. Nach drei
  identischen Suchversuchen innerhalb eines Auftrags beendet StudioPortal die laufende Antwort mit einer Meldung.
- **Arbeitsordner** (Knopf oben rechts im Chat, immer sichtbar) wie bei Coding-Agenten: Ordner oder einzelne Datei, wird über
  Neustarts und „Neuer Chat“ gemerkt (UserDefaults `llmWorkFolder`). PhotoCraft verwendet dauerhaft
  `<Arbeitsordner>/PhotoCraft-Ergebnisse/` (bei einer Einzeldatei neben der Datei). Die vorhandenen datierten
  Unterordner bleiben les- und beschreibbar. Der Ergebnisordner wird vor dem Arbeitsordner als Lesewurzel geprüft,
  damit geöffnete Ergebnisse denselben Schreibpfad behalten. Pro Ergebnisordner läuft jeweils ein Auftrag.
  Versteckte Arbeitsstände `.studioportal-stand-<id>.psd` anderer Sitzungen, die älter als 7 Tage sind, legt der Start einer
  Sitzung in den Papierkorb (`src/Checkpoints.swift`); gespeicherte Chats haben ihre eigene Kopie im Archiv.
- **Speichern:** Bei `doc_save` und `doc_export` legt `pi-photocraft-save.mjs` fehlende Unterordner innerhalb des
  Ergebnisordners an, z. B. bei `Jahr/Art/Person/Periode/Neu.psd`. Ein versehentlich vorangestellter relativer
  Ergebnisordner-Präfix wird entfernt. Symbolische Links als Zielordner und Pfade aus dem Ergebnisordner hinaus
  werden abgewiesen. Die erste Speicherung einer Vorlage oder Dokumentkopie braucht einen neuen relativen Zielpfad.
  Zum Aktualisieren einer vorhandenen PSD ihren absoluten Ergebnispfad öffnen und `doc_save` ohne `path` verwenden.
  Ein expliziter Zielpfad weist vorhandene Ergebnisse ab. Jeder Chat hat einen eigenen versteckten Zwischenstand.
- **PhotoCraft-Werkzeugaufrufe:** `photocraft-stdio.mjs` leitet pro Sitzung jeweils nur einen `tools/call`
  an PhotoCraft weiter. So wird etwa Schließen → Öffnen → Prüfen auch dann der Reihe nach verarbeitet, wenn
  Qwen diese Calls gemeinsam sendet. Bereits laufende Calls dürfen vor dem nächsten abschließen.
- **PSD-Ergebnisse prüfen:** Speicherantworten liefern `absolutePath`. Über diesen Pfad erneut öffnen und die
  Änderung mit `type.info` auf der gespeicherten Ebene nachlesen. Ein relativer Pfad, der sowohl in den Vorlagen
  als auch im Ergebnisordner vorkommt, wird als mehrdeutig gemeldet. Textersetzungen per `command_batch` arbeiten
  auf derselben aktiven Ebene. Nach dem Batch den tatsächlich geänderten Text mit `type.info` prüfen.
  `doc_inspect.clippedTextLayers` meldet sichtbare Textebenen mit Grenzen außerhalb der Leinwand.
  Bei Rechnungen zusätzlich die Summenzeile in der gerenderten Vorschau und die Tabulatoranzahlen zur Vorlage prüfen. Lokale
  Kantenretusche an einer Pixelebenen-Kopie läuft über `layer_soften_corner`. Das Werkzeug sucht einen deckenden
  Pixel der gewählten Ecke und verifiziert die Abnahme von Alpha an diesem Pixel. Erst danach verschieben/drehen.
  Die unveränderte Quelle bleibt bei Bedarf ausgeblendet.
- **PSD-Texte:** Nach jedem Öffnen die aktuelle Ebene prüfen und bevorzugt mit `layer.select` über ihren eindeutigen
  Namen wählen. Bei formatierten Vorlagen nur die betroffenen Textstellen auf der gewählten Ebene ersetzen und
  Absätze, Einzüge, Tabs, Position und Vorschau vergleichen. `type.info` liefert die Absatzanzahl unter
  `paragraphCount` und die Tabulatoranzahl je Absatz unter `tabsByParagraph` (auch bei `type.setStyle`/`type.edit` und in `command_batch` unter `results[].result`). Das Feld
  `paragraphs` beschreibt die Formatläufe: PhotoCraft 0.23.1 fasst gleiche Nachbarn zusammen (Photoshop-PSDs: ein Lauf je
  Absatz), daher z. B. 42 → 1 Lauf nach dem Speichern ohne Verlust; unterschiedliche Absatzformate bleiben erhalten (getestet).
  Pi kürzt MCP-Antworten über 20 KB in der Mitte (Datei mit voller Antwort in `details.fullOutputPath`); dann liest
  `pi-photocraft-save.mjs` die volle Fassung und stellt eine Zeile „Textinfo …: paragraphCount N, K Formatläufe, L Zeilen“ mit Tabulatoranzahlen voran. Bei `doc_inspect` bleibt eine Kurzfassung mit Leinwandmaßen und überbreiten Ebenen erhalten.
  `type.edit.replace` verwendet nullbasierte
  Unicode-Codepunkt-Indizes mit exklusivem Ende, z. B. `start: 4, end: 7` für drei Zeichen. Den Bereich vorher
  gegen den aktuellen Text prüfen: PhotoCraft 0.23.1 kann zu große Indizes ans Textende verschieben.
  Vollständiger Textersatz mit `type.edit` und dem Parameter `text` behandelt bei getrennten Änderungen alles zwischen der ersten und
  letzten Änderung als einen Bereich. Dabei können auch unveränderte Absätze innerhalb dieses Bereichs ihr Format
  verlieren. `type.resolveMissingFonts` ohne Parameter listet fehlende Schriften.
- **Folgerechnungen:** Die letzte fertige PSD als bearbeitbare Kopie öffnen (`image.duplicate` mit `mergedOnly: false`).
  Zuerst fehlende Schriften prüfen. Jede Datumsstelle mit `type.info` ermitteln und mit `type.edit.replace` im selben
  Format und mit gleicher Codepunktzahl ersetzen. Bei gemischten Schriftformaten die betroffenen Zeichen je Formatlauf
  bearbeiten. Unter einem neuen Pfad speichern und die Vorschau mit der Ausgangsdatei vergleichen.
  Beim Test mit einer anonymisierten Rechnungs-PSD blieben nach dem gezielten Ersatz und PSD-Rundlauf alle 44
  Tabulatorpositionen und alle 28 Schriftformatläufe erhalten. Beim Volltextersatz änderten sich alle 44
  Tabulatorpositionen und es blieben 24 Schriftformatläufe. PhotoCraft rendert die Textebene beim ersten Eingriff neu.
  Deshalb kann sich die Vorschau selbst bei gleichen Schriftformaten und gleicher Ebenenposition gegenüber der
  ursprünglichen PSD ändern.
- **Werkzeuge:** PhotoCraft ist nur das Standardwerkzeug. Pi hat zusätzlich `read`, `write`, `edit`, `bash`, `ls`, `find`,
  `grep` und erledigt damit auch Nicht-Bild-Aufträge (z. B. eine `.md` anlegen oder bearbeiten). Die Sandbox erlaubt Schreiben
  nur im Arbeitsordner und im Ergebnisordner, kein Netz. Originale ändert er nur auf ausdrücklichen Auftrag.
- **Sicherheitsstufen** (Knopf neben dem Arbeitsordner, gemerkt in `llmFileMode`, ändern startet Pi neu):
  **Sandbox** (Standard): Löschen/Verschieben/Umbenennen im Arbeitsordner gesperrt (`file-write-unlink`, nur im eigenen
  Ergebnisordner erlaubt); Qwen schreibt stattdessen einen Plan. **Fragen**: die Sperre fällt, dafür lädt Pi die
  Erweiterung `src/pi-permissions.mjs`, die vor jedem nicht rein lesenden bash-Befehl (alles außer einzelnen Lesebefehlen
  wie `ls`, `find` ohne `-delete/-exec`, `stat`; keine Umleitung/Verkettung) und vor `write`/`edit` außerhalb des
  Ergebnisordners fragt; die App zeigt eine Karte über dem Eingabefeld (Pi `extension_ui_request` confirm, der Wächter
  wartet) mit den Antworten wie bei Claude Code: **Ja** (einmal), **Ja, in diesem Chat: mv, mkdir** (bis „Neuer Chat“),
  **Ja, immer hier: mv, mkdir** (je Arbeitsordner gemerkt, UserDefaults `llmAllowRules`) und **Nein** mit optionalem
  „stattdessen …“ (geht als Grund an Qwen). Regeln gelten je Programm (`src/CommandRules.swift`, wie `Bash(mv:*)`): ein
  Befehl läuft ohne Karte, wenn alle Teile (`&&`, `;`, `|`) freigegeben sind; `>` ist eine eigene Regel, für write/edit gibt
  es „Dateiänderungen“. Befehle mit `$(…)`/Backticks oder Wrappern (`xargs`, `sh`, `find`, `python` …) sind nur einzeln
  freigebbar. Das Sicherheitsmenü zeigt die Freigaben und setzt sie zurück. Stopp lehnt ab; jede Entscheidung steht im Verlauf. **Alles erlauben**: ohne Sperre und
  ohne Rückfrage. In allen Stufen: kein Netz, nichts außerhalb von Arbeits- und Ergebnisordner. iPhone: immer Sandbox.
- **Steuern während der Arbeit:** „Senden“ während eines Pi-Auftrags schickt Pis `steer`: Qwen liest die Nachricht nach dem
  aktuellen Werkzeugschritt und macht weiter (kein Abbruch). Kommt sie zu spät (Pi schon fertig), holt StudioPortal sie mit
  `clear_queue` zurück, nachdem Pi sie bestätigt hat (Pi bearbeitet Befehle nebenläufig), und sendet sie als nächsten Auftrag.
  **„Danach“** (⇧⌘↩) legt Folgeprompts in eine Warteschlange über dem Eingabefeld (einzeln entfernbar); sie gehen nach
  jeder fertigen Antwort einzeln los, nach Stopp/Fehler zurück ins Eingabefeld. Im normalen Chat landet „Senden“ dort auch.
- **Verlauf:** Unter jeder Pi-Antwort stehen Denken, jeder Werkzeugschritt mit Argumenten (Datei, Ebenen-ID, Befehl) und
  Fehler untereinander, live während der Arbeit, danach aufklappbar. **Stopp** behält Text, Denken und Schritte; Pi behält
  seinen Verlauf, „weiter“ setzt fort (eine neue Pi-Sitzung bekommt die Schritte als Kontext).
- **PhotoCraft verwenden** aktiviert Pi im RPC-Modus mit Bildwerkzeugen. Ein Pi-Prozess und ein lokaler
  PhotoCraft-MCP-Prozess bleiben für Folgeaufträge im selben Chat offen. Das Modell erhält einen kurzen Systemprompt und
  die ausgewählten MCP-Werkzeuge. Standard für PhotoCraft ist **Mittel**, unabhängig von der Denkstufe des normalen Chats.
  Beim Musterdokument mit Textänderung, Stempelkopie, Drehung und Export war Mittel bei gleicher Ergebnisqualität
  schneller als Niedrig und Hoch.
- StudioPortal startet Strata wie beim normalen Chat. Pi und PhotoCraft laufen mit einer macOS-Prozesssandbox.
  Nur ein lokaler Port ist für Pi erreichbar. StudioPortal leitet diesen Port an Strata auf bigkis LAN-Adresse weiter, ist sie nicht erreichbar (MacBook unterwegs),
  über Tailscale (`GPU-SERVER-IP:8080`). Die Sandbox bekommt echte Pfade (`realpath`, auch `/private/tmp`).
  In der Sandbox stehen systemweit installierte Schriften aus `/Library/Fonts` zur Verfügung. Einzeldateien werden in
  die private Sitzung kopiert. Einen ausgewählten Arbeitsordner kann Pi direkt lesen und auflisten (`list_documents` über das gebündelte Node).
  Nur wenn der Ordner nicht beschreibbar ist oder die Vorlage aus einem gespeicherten Chat stammt, landen Ergebnisse in
  `~/Library/Application Support/StudioPortal/PhotoCraft-Ergebnisse`. Die App zeigt Exporte und Vorschauen im Chat an (alle Vorschauen eines Auftrags, je Dokument die neueste, mit Dateinamen).
- **Viele Dateien:** Im Arbeitsordner listet `list_documents` Dateien und Unterordner (80 je Seite, `recursive: true` für alle
  Unterordner) mit `modified`/`created` (Ortszeit; auch für Ordner und den abgefragten Ordner selbst, Feld `folder`) und `bytes` – so findet Qwen z. B. „alle Dateien von 2026“ ohne sie zu öffnen. Qwen öffnet jede Datei,
  sieht sie über `doc_render_preview` an, liest Ebenen/Texte mit `doc_inspect` und schließt sie mit `doc_close` (sonst
  bleiben alle offen). Ein Auftrag bricht nur ab, wenn Pi 5 min nichts meldet oder nach 60 min insgesamt.
  Gemessen 20.11.2026: 43 Bilder prüfen 614 s, 53k Kontext, alle 6 zu dunklen gefunden, von 6 gedrehten nur 1 (runde
  Motive schwer); 5 PSDs (bis 53 MB, CMYK, Smart Objects) mit Ebenen, Texten und einem Widerspruch zwischen zwei Dateien
  in 87 s, PhotoCraft höchstens ~950 MB RAM; Textebene in einer PSD geändert und als PSD + PNG gespeichert in 44 s.
  Fallen-PSD (20 Ebenen: 2 Gruppen, 2 ausgeblendet, 3 Masken, Schatten/Kontur, Multiplizieren 60 %, Einstellungs- und
  Füllebene; Referenz mit `psd-tools` ausgelesen): Beschreibung fehlerfrei. Aufträge ohne Werkzeugnamen gelöst: Ebene
  einblenden + Text ändern, Effekt entfernen/hinzufügen, Textfarbe, Smart-Filter auf die per Lage beschriebene Ebene,
  Bild auf 50 %, Zuschnitt, Formebene, Ebenen einzeln exportieren (`doc_export_layers`), Abbrechen und Weiterarbeiten,
  Wiederaufnahme aus gespeichertem Stand. Schwächen: Qwen legt teils Zwischen-/Fehlversuchsdateien ab und landet beim
  Speichern manchmal in einem Unterordner `PhotoCraft-Ergebnisse/` des Ergebnisordners (der Chat zeigt Ergebnisse in
  Unterordnern mit an).
- **/compact [Schwerpunkt]** im Eingabefeld fasst den Verlauf sofort zusammen (während einer Antwort: kommt in die
  Warteschlange). Mit PhotoCraft/Websuche: Pis `compact` in der laufenden Sitzung (Pi behält die letzte Runde und ~20k Token
  wörtlich; bei kleinerem Verlauf meldet es „Noch nichts zum Zusammenfassen“). Normaler Chat: dieselbe Zusammenfassung wie
  Auto-Compact, aber über den ganzen bisherigen Verlauf. Die letzte Antwort bekommt den Vermerk „Verlauf zusammengefasst“.
- **Automatisch gespeichert** wird jeder Chat nach jeder Antwort (auch nach Stopp), außer solange **„Temporär“** oben
  eingeschaltet ist. Antworten werden als Markdown dargestellt (Tabellen, Listen, Code) und haben einen Kopieren-Knopf.
  Angehängte Textdateien (`.md`, `.txt`, `.csv`, `.json`) haben eine aufklappbare Vorschau (Markdown gerendert); die
  gerenderte PhotoCraft-Bildvorschau erscheint nur, wenn die Antwort Bilder/PSDs (oder gar keine Datei) enthält.
- **Chats → Chat speichern** (⌘S, auch von Hand) sichert den Verlauf, die ausgewählte Vorlage und, sofern vorhanden, den zuletzt gespeicherten
  PSD-Arbeitsstand und den Verweis auf einen gewählten Arbeitsordner unter `~/Library/Application Support/StudioPortal/Chats`. Gespeicherte Chats können
  dort erneut geöffnet und fortgesetzt werden.
- **Websuche** ist für neue und wieder geöffnete Chats ausgeschaltet. Eingeschaltet kann Pi bei Bedarf öffentliche
  Suchbegriffe direkt an Bing senden. Der gebündelte Helfer läuft nur während einer freigegebenen Pi-Sitzung und fragt per HTTPS die RSS-Ergebnisse ab. Er bekommt ausschließlich Werkzeugaufrufe über lokale Pipes. Pi selbst behält seine Netzwerksperre. Kein Container, API-Schlüssel oder dauerhaft laufender Suchdienst erforderlich.

#### Diktat im Mac-Chat (`src/Dictation.swift`)
- Mikrofonknopf neben dem Eingabefeld: klicken, sprechen, nochmal klicken. Der Text wird ans Eingabefeld angehängt und
  kann vor dem Senden korrigiert werden. Funktioniert im normalen Chat und im PhotoCraft-Modus.
- Erkennung **nur lokal** mit `whisper-cli` (Homebrew `whisper-cpp`, Metal) und **Whisper large-v3-turbo German**
  (primeline, ggml q5_0 von `cstr/whisper-large-v3-turbo-german-ggml`, Apache-2.0, 574 MB) unter
  `~/Library/Application Support/StudioPortal/Modelle/whisper-turbo-de-q5_0.bin`. Fehlt die Datei, lädt die App sie
  einmalig und prüft SHA-256. Die Aufnahme (16 kHz mono WAV im Temp-Ordner) wird nach der Erkennung gelöscht; Audio
  verlässt den Mac nicht. Apple-Spracherkennung wird bewusst nicht genutzt.
- Auswahl (20.11.2026, 10 echte Diktate des Nutzers mit Bildaufträgen): Whisper Turbo DE 8,3 % WER, 23/25
  Schlüsselwörter; Whisper Turbo 10,1 %; Parakeet v3 15,6 % (Zahlen als Wörter); Moonshine Small DE 27,5 %
  (sinnentstellend). Mac mini M4: ~1,1–1,7 s je Diktat (Whisper rechnet immer ein 30-s-Fenster), max. ~0,9 GB RAM nur
  während der Erkennung; das Modell lädt in ~0,16 s und bleibt nicht im Speicher.

### 3.15 iPhone-App und iPhone-Dienst (`ios/`, `src/Gateway.swift`)
- **iPhone-App** (SwiftUI, `ios/project.yml` → `xcodegen generate`, Bundle-ID `local.beispiel.studioportal.iphone`):
  Erstellen (Bild, Musik, Video, 3D aus Foto), Chat, Bibliothek, Rechner. Erstellen folgt seit 18.11. dem Mac-Aufbau:
  Ergebnis-Feed in der Mitte (Karten mit Einstellungszeile, „Übernehmen“, „Variieren“), Composer unten (Text, Options-Pills
  als Menüs: Stil, Format, Länge, Gesang/Liedtext-Blatt, Foto; runder Senden-Knopf), Art-Umschalter oben. Mehrere Aufträge
  laufen parallel im Feed; der Feed gilt nur für die laufende Sitzung. Bewusst ohne Seeds/CFG/Steps. Ergebnisse lassen sich aufs
  iPhone holen, teilen und in Fotos sichern. Funktioniert, sobald Tailscale auf dem iPhone an ist.
- **iPhone 1.1:** App-Icon aus dem Mac-Symbol. Gemeinsame Bibliothek mit Filter „Auf dem iPhone“. Bilder, Musik und Videos
  werden beim Öffnen heruntergeladen. Cache und explizite Offline-Dateien haben getrennte Status. Downloads lassen sich nach
  Dateityp, Anzahl, WLAN und Speicherlimit automatisch aktualisieren, solange iOS die App aktiv hält. Pro Dateityp einzeln
  löschbarer Cache und optionales Entfernen beim Verlassen der Dateiansicht.
- **iPhone 1.1:** Erweiterte Optionen für Bild, Musik, Video und 3D. Der Werkzeug-Tab bietet Modellimport per Link,
  Bildvergleiche sowie Datei öffnen, Szenendaten, Mesh-Prüfung, Vorschau, Einzelbild-Render und Speichern in einer separaten
  Blender-Sitzung auf bigki. Der Chat kann Textverläufe im Mac-Archiv ablegen und auf beiden Geräten öffnen. PhotoCraft
  bearbeitet ein ausgewähltes Bibliotheksbild oder Foto über den Mac mini. Websuche bleibt pro neuem Chat ausgeschaltet.
  Das Diktat sendet seine WAV per Tailscale an den Mac mini. Whisper erkennt sie dort lokal und die WAV wird gelöscht.
- **iPhone-Dienst** `studioportal serve` auf dem Mac mini: HTTP nur auf 127.0.0.1:8791 (LaunchAgent
  `local.beispiel.studioportal.gateway`), ins Tailnet gebracht mit `tailscale serve --bg --https=8790 http://127.0.0.1:8791` →
  `https://DEIN-MAC.DEIN-TAILNET.ts.net:8790` (nur Tailnet, gültiges Zertifikat). Schlüssel (Bearer) in
  `~/Library/Application Support/StudioPortal/iphone-token`; `studioportal setup-iphone` richtet alles ein und zeigt ihn.
- Endpunkte: `/api/ping|status|presets|library`, `POST /api/upload` (Foto → PNG in den iPhone-Uploads),
  `POST /api/run {tool,args}` → Job, `/api/job/<id>` (Fortschritt, Teiltext beim Chat), `/cancel`, `/api/file` (nur
  Bibliotheksordner, Range für Audio/Video), `/api/thumb`. Die Aufträge laufen über dieselben `AgentOps` wie CLI/MCP.

### 3.16 Sprache (Fish Audio Drama 3) & Telefon-Test (2+1 GPU-Split)
- **Engine auf bigki (`~/drama3/audio.cpp`)**: `0xShug0/audio.cpp` (GGML, C++/HIP `gfx906`, HIP Graphs aktiviert, `-march=native` AVX-512), kompiliert mit den Modellen `fish_drama3`, `qwen3_tts`, `nemotron_asr`, `qwen3_asr`, `smart_turn`, `firered_vad`.
- **Auf der MI50 (`gfx906`) angepasst**:
  - Drei `CUDA`-exklusive Pfade in `audio.cpp` auf `uses_ggml_cuda_or_hip_backend` freigeschaltet (`fish_drama3/backbone.cpp` Identity-Reshape-Elision, `activation_modules.cpp` fusionierte `SnakeBeta1dModule`-Kette für den Fish-DAC-Codec, `attention_internal.h` `FastPackedProjection4Module`).
  - Modellwahl für `gfx906`: `Jmica/Drama-3-GGUF` V2 (Checkpoint `78e5ab7`) → `drama-3-backbone-8bit-F32-routers-experts-Q4_K_S.gguf` (22,97 GiB: Q4_K Experten, FP32 Router, Q8_0 Backbone/Embedding/Head statt BF16 ohne Vega20-Hardware-Support, FP16 Tower/Codec; `moe_cpu_expert_layers=0`, komplett resident in 1× 32 GB MI50).
  - Gemessene Werte auf **1× MI50 (OCuLink GPU 1)** mit `fish_drama3.perf_mode=cuda_perf` (`fused_moe`, `device_sampling`, `kv_cache_alignment=256`, `codec_async_decode=true`, `codec_batch_frames=2`):
    - **Fish Audio Drama 3 V2:** Load **23,5 s**, **TTFA 202 ms (warm)**, **RTF 0,641× (1,56× schneller als Echtzeit)**, **23,13 GiB VRAM**, **73–91 W / 79–82 °C** (deutlich unter 150 W Cap).
    - **Qwen3-TTS 1.7B CustomVoice Q8 (`perf_mode=cuda_perf`, Sprecher `Ryan`):** Load **2,3 s**, **TTFA 34–75 ms (warm)**, **RTF 0,230× (4,35× schneller als Echtzeit)**, **~2,7 GiB VRAM**.
  - **STT & Turn-Detection auf i5-11600K AVX-512 CPU (0 MB VRAM, null GPU-Konflikt):**
    - **Nemotron 3.5 ASR Streaming 0.6B Q8 (`de-DE`):** 888 MB RAM, **~190 ms** für reale deutsche Telefon-Äußerung (~21× schneller als Echtzeit).
    - **Pipecat Smart Turn v3.2 (F32):** 31 MB RAM, **25–36 ms** auf CPU (erkennt deutsche Satzmelodie für Turn-Ende vs. Denkpause).
- **2+1 GPU-Split im Telefon-Test (`operation: "phone"`):**
  - **GPU 0 + GPU 2 (beide direkten CPU-Slots):** Strata `v0.2.16` `mtp1` (`~/drama3/strata-phone-2gpu.json`, ohne Vision-Encoder, Port 8081, 32k Kontext, `layer_split: "24"`, `24576` Experten-Slots = 100 % resident, `reasoning_effort: "none"` + `enable_thinking: false`; **113–150 t/s Prefill / 86–91 t/s Decode**).
  - **GPU 1 (OCuLink `GPU-215c20a173497dd3`):** `audiocpp_server` (Port 8035) für Streaming-TTS (`Drama 3` oder `Qwen3-TTS`) per HTTP SSE (`/v1/audio/speech`, `pcm_s16le`). **Drei gecastete deutsche B2B-Vertriebsstimmen (`~/drama3/voices/{laura,lukas,jonas}-de.wav`, ~3,0–3,15 s):** *Laura · Warm & Souverän* (Standard, warme weibliche Bruststimme mit leichtem Lächeln), *Lukas · Warm & Locker* (entspannter männlicher Gründer-Ton) und *Jonas · Tief & Ruhig* (souveräner Bariton) – automatisch über `voice_preset` + kurzes Drama-3-Regietag `[calm, warm]` (ohne Murmel-Artefakte) und `reference_cache_slots` (0 ms Re-Encoding, **~430–560 ms TTFA / 0,58–0,61× RTF**) gesteuert. Satz-Splitting trennt sauber an Satzenden (`.!?`).
  - **CPU (i5-11600K):** `audiocpp_server` (Port 8036) für `nemotron-asr` + `smart-turn`.
  - **Persistente Telefon-Sitzung (`action: "session"`) & KV-Cache-Anker (`warmup`):** Beim Klick auf *Anruf simulieren* öffnet `PhoneSessionClient` **eine** offene SSH-JSONL-Verbindung für den gesamten Anruf (0 ms SSH-/Python-Startzeit je Zug, sofortiger Barge-In-Abbruch via `cmd: "cancel"` ohne Verbindungsabbau) und wärmt Stratas KV-Cache mit dem Systemprompt vor. Jede Sprachäußerung läuft in einem Schritt (`cmd: "converse"`: Smart Turn → Nemotron ASR → `transcript` → Strata ohne Reasoning → Drama 3 mit gecachter Stimme).
  - Parallelstart aller Komponenten in **~51 s**, automatischer Leerlauf- & 91-°C-Temperatur-Stopp nach 15 min; beim Wechsel zu 3-Karten-LLM stoppt der Worker eigene Sprach-/Telefon-Server automatisch.
- **macOS-App (`SpeechStudio.swift`, `SpeechToolView.swift`, `PhoneCallStudio.swift`, `LiveKitPhoneStudio.swift`, `PhoneCallView.swift`):**
  - Tab **„Sprache“**: Live-Streaming-Wiedergabe (`AVAudioEngine` + `AVAudioPlayerNode`), Regie-Tags (`[laughs]`, `[sighs]`, `[whisper]`, `<|speaker:0|>`), Voice Cloning (WAV/M4A/MP3-Konvertierung), Ablage in `~/Music/StudioPortal-Sprache` (in Bibliothek & Mac-Sync integriert).
  - Tab **„Telefon-Test“** mit Umschalter **„LiveKit Agent“** *(Standard)* vs. **„Klassisch (Backup)“**:
    - **LiveKit Agent (`LiveKitPhoneStudio.swift`, `src/livekit_phone_agent.py`, `src/livekit_web_bridge.py`):** Lokaler `livekit-server` (`127.0.0.1:7880`, Homebrew `livekit`) + isolierte Python-3.12-Venv (`~/Library/Application Support/StudioPortal/livekit-venv`, `livekit-agents 1.8.13`, `silero`, `openai`, `elevenlabs`, `deepgram`) + eingebettete WebRTC-Oberfläche (`WKWebView` über `127.0.0.1:7891` mit echtem WebRTC-AEC/NS/AGC, Silero VAD, `resume_false_interruption` und „Im Browser öffnen“). Vier umschaltbare Profile: **100 % Lokal (`bigki`)** über `phone/session` (`llm_stream`/`tts_stream`/`listen`), **Hybrid (`bigki` Qwen-LLM + ElevenLabs-Stimme)**, **Cloud (`ElevenLabs + OpenAI`)** und **Cloud (`OpenAI Realtime`, Audio→Audio)**. API-Schlüssel bleiben strikt lokal unter `~/Library/Application Support/StudioPortal/livekit-keys.json` (`0600`).
    - **Klassisch (Backup) (`PhoneCallStudio.swift`):** Bisherige native Swift-`AVAudioEngine`-/`VoiceProcessingIO`-Pipeline bleibt vollständig als umschaltbares Backup erhalten. Aufzeichnungen beider Modi landen unter `~/Music/StudioPortal-Sprache/Anrufe/`.
  - CLI/MCP: `studioportal speech …`, `studioportal phone status|start|stop`, MCP `create_speech`, `speech`, `phone`, `guide topic=sprache|telefon`.

## 4. Regeln, die immer gelten
- Fremde Jobs nie beenden; Blender und fremde GPU-Jobs haben Vorrang.
- Keine Änderungen an Systemdiensten, den `mi50-*`-Diensten oder Skripten/Projekten anderer (z. B. `h3.sh`,
  `~/hunyuan3d-2mv`, `~/blender-mi50`, `~/blender-live`, Dateien anderer Agenten). Neues nur unter `~/.local/share/3d-modelle-app`.
- Auf bigki nur eigene Dateien löschen; Platz ist knapp.
- Lizenzen: KI-Musik bei Veröffentlichung kennzeichnen. Fish Audio Drama 3 (Fish Audio Community License v1.0, „Built with Fish Audio“): frei für Forschung/Privat & kommerziell unter 500.000 US-$/Jahr, kein gehosteter TTS-/Cloning-API-Dienst für Dritte, kein Voice Cloning realer Personen ohne Einwilligung. MiniMax H3 (Bild/Video): nur privat, nicht in der EU veröffentlichen,
  nicht für Werbung. Hunyuan3D-Omni / -2mv (Tencent-Community-Lizenz): gilt nicht in EU, UK, Südkorea – nur privat.

## 5. So wird geändert und ausgerollt
1. Code in `src/` ändern. Python-Teile für bigki: `bigki_worker.py`, `gpu_broker.py`, `prepare_views.py`,
   `blender_session.py`, `studio_figur.py`, `studio_helfer.py`, `omni_figur.py` (Liste in `setup_bigki.py`).
2. `./build.sh` (räumt vorher `build/` auf) und `python3 setup_bigki.py --files-only` (Mac mini offline:
   `--files-only --via-session`).
3. App auf beide Macs kopieren (`~/Applications/StudioPortal.app`), App neu starten.
4. **Diese Datei aktualisieren** (betroffene Abschnitte + Änderungsprotokoll).
5. **Tests**: `python3 -I tests/test_worker.py` (Worker + Broker auf Fake-bigki, ohne GPU, ~25 s),
   `python3 -I tests/test_agent.py` (CLI-Parameter werden vor bigki abgelehnt, < 1 s), `python3 -I tests/test_compaction.py`
   (Auto-Compact des Mac-Chats, ~2 s), `python3 -I tests/test_photo_folder.py` (Arbeitsordner-Helfer, Datum, rekursiv),
   `python3 -I tests/test_chat_archive.py` (Pi-Modus und bestehende Chat-Archive),
   `node --test tests/test_photo_save.mjs` (Unterordner für PhotoCraft-Speicherpfade, begrenzt auf den Ergebnisordner),
   `python3 -I tests/test_pi_steer.py` (echtes Pi mit Fake-Modell: Steuern, Stopp + Weiter, verspätete Nachricht, /compact, Rückfrage im Modus „Fragen“ inkl.
   „Nein, stattdessen“, ~8 s), `python3 -I tests/test_command_rules.py` (Freigabe-Regeln je Programm, ~2 s), `python3 -I tests/test_checkpoints.py` (alte Arbeitsstände in den Papierkorb, ~2 s; legt eine Testdatei in den Papierkorb), `tests/run_blender_tests.sh`
   (Figurtest in Blender auf bigki: `mensch` + `bvh_laden` mit CMU-Referenzclip, Füße/Hüfte/Laufrichtung; `--lang` +
   `auto_rig`, ~10 min CPU).
   Änderungen am Chat, Pi oder PhotoCraft zusätzlich im sichtbaren StudioPortal-Fenster mit Qwen prüfen.
   Bei Schreibvorgängen die erzeugte Datei unabhängig von der Modellantwort kontrollieren.
6. **Git**: Repo auf dem Mac mini (`~/Developer/ModelleZuBlender`, Branch `main`), Remote `origin` =
   privates Arbeits-Repo `StudioPortal` (volle Historie, lokale Adressen). Das öffentliche
   Portfolio-Repo `StudioPortal` wird ausschließlich über `python3 -I share/publish_public.py --push`
   als bereinigter Einzel-Commit ohne private Historie, IPs oder Schlüssel aktualisiert.
   Keine Schlüssel ins Repo (iPhone-Token, Strata-Key, Cloud-Keys bleiben in `~/Library/Application Support/StudioPortal`).
7. **Weitergeben** (z. B. an Kollegen mit eigener GPU): `python3 -I share/make_zip.py` → `~/Desktop/StudioPortal-<datum>.zip`.
   Inhalt = letzter Commit ohne Git-Verlauf; Adressen, Rechner-/Benutzernamen, Host-Key und Bundle-IDs werden durch
   Platzhalter ersetzt, danach prüft das Skript auf Reste und bricht sonst ab. Dazu `share/LIESMICH-ZUERST.md`
   (was fehlt und selbst geladen wird – Modelle, Whisper, Pi –, Platzhalter-Tabelle, Umbau MI50 → einzelne CUDA-Karte).
   `server/` enthält die Server-Skripte, die sonst nur auf bigki lägen: `hunyuan3d-2mv/` (generate.py, decode_latents.py,
   project_colors.py), `figur/` (Download-/Setup-Skripte für Omni und UniRig, flash_attn-CPU-Ersatz, UniRig-Config), `blender/anim_setup.py`.
   Neue persönliche Angaben im Code → Muster in `share/make_zip.py` ergänzen. Vorher committen (es zählt `HEAD`).

## 6. Offene Punkte
- iPhone-App ist lokal per Xcode installiert. Umfangreiche Blender-Bearbeitung bleibt am Mac.

## 7. Änderungsprotokoll

- **28.11.2026** – Sechs Blender-/Workflow-Verbesserungen umgesetzt (`src/bigki_worker.py`, `src/blender_session.py`, `src/BlenderVideo.swift`, `src/Agent.swift`, `src/Machine.swift`, `src/Guide.swift`, `src/SettingsView.swift`): (1) inkrementeller SHA-256-Ordner-Sync (`studioportal sync <quelle> [ziel]`, MCP-Tool `sync_files`) für Skripte, Schriften und Assets; (2) `blender python --script` setzt jetzt `__file__` und ergänzt `sys.path` um den Skriptordner, und `--mit-ordner` / `with_dir=true` synct den Projekt-/Skriptordner automatisch vorab nach bigki; (3) `blender_render` liefert vollständige Render-Telemetrie im Ergebnis-JSON (`device`, `cards`, `card_count`, `denoiser`, `samples`, `samples_reached`, `adaptive_threshold`, `setup_s`, `render_s`, `wait_s`, `kernel_compiled`, `blender_time_s`); (4) `status` und `blender_session status` melden CPU-Governor, EPP, Takt (MHz), Loadavg und den Blender-Build-Typ (`Release`); (5) veraltete `stori`-Hinweise in Tool-Beschreibungen, Übersicht und Doku auf `~/Pictures/H3 Studio/Bilder` bereinigt.
- **25.11.2026** – Privates Arbeits-Repo nach `StudioPortal` umgezogen und bereinigtes öffentliches Portfolio-Repo unter `StudioPortal` veröffentlicht (`share/publish_public.py`, inkl. RTX-3090-/CUDA-Anleitung `LIESMICH-ZUERST.md` und Portfolio-`README.md`, ohne private Historie, IPs, Hostnamen oder Schlüssel).
- **24.11.2026 (11)** – Seitenleiste im Tab *Telefon-Test* profilabhängig gemacht (`src/PhoneCallView.swift`, `src/LiveKitPhoneStudio.swift`): Bei **Hybrid** und **Cloud (ElevenLabs)** erscheint statt lokalem Drama 3 direkt der Abschnitt **„Stimme (ElevenLabs)“** mit live über `/v1/voices` geladener Stimmenliste aus dem eigenen Konto (inkl. **Yeon – Deep and Emotional** ganz oben, Reload-Button und Modell-Picker `eleven_v4_turbo`); bei **OpenAI Realtime** erscheinen die Realtime-Stimmen, und **Drama 3 / Qwen3-TTS** nur noch bei **100 % Lokal** bzw. im *Klassisch (Backup)*-Modus.
- **24.11.2026 (10)** – ElevenLabs **Yeon – Deep and Emotional** (`WNpDisiMIzLl7ft2rYeN`, Deutsch) mit **`eleven_v4_turbo`** und nativem **`pcm_24000`**-WebSocket-Streaming (ohne MP3-Decode, gemessen **149 ms TTFA warm / 243 ms kalt**) fest im Hybrid-Profil verankert und per Live-WebRTC-E2E-Test (`bigki` Qwen 3.8 Flash + ElevenLabs v4 Turbo + Yeon, 1.705 Frames @ 48 kHz) verifiziert; Hybrid-Bereitschaftsprüfung erkennt laufendes `bigki`-LLM + CPU-STT direkt ohne unnötigen Drama-3-Start.
- **24.11.2026 (9)** – ElevenLabs **v4 Turbo** (`eleven_v4_turbo`, nativer `text-to-dialogue`-WebSocket in `livekit-plugins-elevenlabs 1.8.13` ohne inkompatibles `streaming_latency`) als Standardmodell ergänzt (plus `eleven_v4`, `eleven_v3_conversational`, `eleven_v3`), automatische Auflösung von Stimmnamen wie `Yeon` auf die echte ElevenLabs-`voice_id` und automatisches Speichern der API-Schlüssel bei Eingabe (`livekit-keys.json`, `0600`).
- **24.11.2026 (8)** – **LiveKit Agents** als neuen Standard-Telefon-Stack in StudioPortal integriert (`src/livekit_phone_agent.py`, `src/livekit_web_bridge.py`, `src/LiveKitPhoneStudio.swift`), bisherige native Pipeline vollständig als **„Klassisch (Backup)“** im Header von *Telefon-Test* erhalten. Vier umschaltbare Profile (*100 % Lokal (bigki)*, *Hybrid (bigki LLM + ElevenLabs)*, *Cloud (ElevenLabs + OpenAI)*, *Cloud (OpenAI Realtime)*), lokaler `livekit-server 1.13.11` + `livekit-agents 1.8.13` (`silero`, `openai`, `elevenlabs`, `deepgram`), WebRTC-AEC in eingebetteter `WKWebView` + Browser-Fallback, `llm_stream`/`tts_stream` in `bigki_worker.py` (`phone/session`) ergänzt, Cloud-API-Schlüssel lokal unter `livekit-keys.json` (`0600`).
- **24.11.2026 (7)** – VAD-Loop-Bug im Telefon-Test behoben: `maxReached` in `processVADFrame` umging bisher `!listenInFlight` und sendete bei anhaltendem Hintergrundrauschen denselben 18-s-Puffer pro Audio-Frame mehrfach parallel; jetzt strikt mit `!listenInFlight` gegated, Puffer bei `forceFinal` sofort geleert, adaptiver `noiseFloor` gegen Dauer-Auslösung (Schwelle `0,018`, max. 12 s) und serverseitige Serialisierung aktiver Turns in `phone_session`.
- **24.11.2026 (6)** – Telefon-Test Hänger nach Turn 1 behoben: `StreamingPCMPlayer` nutzt `.dataPlayedBack` plus deterministische Ablaufzeit (`estimatedFinishDate + 0,35 s`), damit hängende `AVAudioPlayerNode`-Callbacks unter `VoiceProcessingIO` das Zurückschalten auf „Hört zu“ nie blockieren; `noiseFloor` wird während eigener Wiedergabe eingefroren und beim Zurückschalten zurückgesetzt, Hör-Schwelle für VoiceProcessingIO auf `0,010` empfindlicher gestellt.
- **24.11.2026 (5)** – B2B-Vertriebsstimmen-Casting & Akquise-Playbook: Stimmpsychologie-Recherche (Gong Labs, DACH-Kaltakquise) + Drama-3-Director-Tag-Tests (2-Wort-Tags `[calm, warm]`/`[warm, smiling]` sauber ohne Bleed-Through; lange englische Tags vermieden). Drei kuratierte deutsche Vertriebsstimmen im UI wählbar (`Laura · Warm & Souverän` als Standard, `Lukas · Warm & Locker`, `Jonas · Tief & Ruhig`), Master-Akquise-Playbook (kein „Haben Sie kurz Zeit?“, kein kaltes Preisnennen, kein falsches „Herr/Frau“, entspannte Einwandbehandlung für Keine Zeit / Schon Agentur / Kein Interesse / Preis / Wer sind Sie?). Live im 7-Turn-Hardcore-Einwand-Test für Laura (63,5 s) und Lukas (73,1 s) komplett abgehört: **210–251 ms LLM-TTFT (136–158 t/s Prefill · 76–136 t/s Decode)**, **0,58–0,64× TTS-RTF**, 100 % konstante natürliche Stimme.
- **24.11.2026 (4)** – Live-6-Turn-Akquise-Test & Echtzeit-Feinschliff: persistente bidirektionale SSH-Sitzung (`phone/session`, `PhoneSessionClient` – spart ~250 ms SSH-/Python-Overhead je Zug und bricht bei Barge-In per `cmd: "cancel"` ohne Neuverbindung ab), kompaktere 1,66-s-Stimmreferenz (`lukas-de.wav`, ~396–460 ms TTFA / 0,60× RTF, Standard-Temperatur `0,78`), natürliches Satzende-Splitting ohne Komma-Unterbrechungen mitten im Satz und neutrale Begrüßung ohne falsches „Herr/Frau“-Raten. Gemessen im 6-Turn-Gespräch (6 realistische Hotel-Clips inkl. Zögern „Ähm, ja, also…“ + 4 Einwände): Smart Turn **6/6 (100 %)** in **24–26 ms**, Mac-End-to-End First-Audio **1,08–1,23 s** (nur 20–42 ms über Server-E2E), 100 % konstante Stimme über alle 56,7 s Audio.
- **24.11.2026 (3)** – Telefon-Test Stimme & Antwortzeit optimiert: konstante deutsche Standardstimme (`~/drama3/voices/lukas-de.wav` + `options.reference_text`, im Drama-3-Referenzcache gehalten → 100 % identische Stimme über alle Sätze bei ~418–430 ms TTFA / 0,604× RTF), `reference_text`-Feld für Voice Cloning in `options` korrigiert, Ein-Sprung-Pipeline `phone/converse` (spart den zweiten SSH-Roundtrip), kompakter Systemprompt + automatischer KV-Cache-Anker (`phone/warmup`) bei Anrufstart, vollständiges 3-Komponenten-Vorwärmen (STT + Smart Turn + Drama-3-Referenz + Strata), ungenutzte `vision`-Sektion aus `strata-phone-2gpu.json` entfernt, straffere VAD-Stillezeiten (260 ms / 900 ms) und Reasoning garantiert aus (`reasoning_effort: none`, `enable_thinking: false`). Live-Messung 2-Turn-Gespräch auf `bigki`: Turn 1 **25 ms Smart Turn / 135 ms STT / 189 ms LLM-TTFT (117 t/s Prefill, 86 t/s Decode) / 418 ms Drama-3-TTFA → 897 ms Server-E2E (1,15 s inkl. SSH)**; Turn 2 **185 ms STT / 222 ms LLM-TTFT (138 t/s Prefill, 72 t/s Decode) / 430 ms TTFA → 1,05 s Server-E2E**.
- **24.11.2026 (2)** – Telefon-Test Audio-Engine auf macOS gehärtet: `mainMixerNode` vor `setVoiceProcessingEnabled(true)` initialisiert, nativer Tap (`format: nil`) mit direktem Kanal-0-Resampling (3-Kanal-VoiceProcessingIO → 16 kHz Mono) und automatischem Fallback ohne VoiceProcessingIO bei `-10875`.
- **24.11.2026** – Neu: **Fish Audio Drama 3 V2** (Tab *Sprache*, CLI/MCP `speech`/`create_speech`) und **Live Telefon-Test** (Tab *Telefon-Test*, Akquise-Anruf-Simulator mit 2+1-GPU-Split, Apple VoiceProcessingIO AEC, Soft Barge-In mit 40-ms-Ducking & 65-ms-Cosinus-Fade-Out + `[unterbrochen]`-Kontextkürzung). `0xShug0/audio.cpp` für MI50 `gfx906` mit HIP Graphs + 3 freigeschalteten HIP-Fast-Paths gebaut (`fish_drama3`, `qwen3_tts`, `nemotron_asr`, `smart_turn`, `firered_vad`). Messwerte auf 1× MI50 (OCuLink GPU 1): Drama 3 V2 **202 ms TTFA / 0,641× RTF (1,56× Echtzeit) / 23,13 GiB / 73–91 W**; Qwen3-TTS 1.7B `cuda_perf` **34–75 ms TTFA / 0,230× RTF (4,35× Echtzeit)**; Nemotron 3.5 ASR (CPU `de-DE`) **~190 ms**; Smart Turn v3.2 (CPU) **25–36 ms**; 2-Karten-Strata (GPU 0+2, 32k Kontext) **113–150 t/s Prefill / 86–91 t/s Decode**.
- **21.11.2026** – Behaltener Verlauf beim Auto-Compact im Kontextmenü auf 20k, 30k oder 40k einstellbar.

- **21.11.2026** – Native Qwen-Rechnungsprobe mit fiktiver PSD: verifizierte lokale Kantenretusche als PhotoCraft-MCP-Werkzeug ergänzt.
- **21.11.2026** – PhotoCraft-Aufrufe pro Sitzung serialisiert, Vorschauen der aktiven Datei zugeordnet und Prüfwerte für Textüberlauf und Absatz-Tabs ergänzt.
- **20.11.2026** – Native Abnahme von Chat-, Pi- und PhotoCraft-Änderungen mit Qwen als festen Prüfschritt dokumentiert.
- **20.11.2026** – LLM-Chat: mehrere PhotoCraft-Vorschauen pro Antwort (je Dokument die neueste, höchstens 12, mit Dateinamen als Raster; vorher überschrieb jede Vorschau die vorige). `ChatMessage.previews`, alte Chats mit `preview` bleiben lesbar.
- **20.11.2026** – `paragraphCount` auch bei großen Textebenen: Pi kürzt Antworten über 20 KB, die Erweiterung wertet dann die gespeicherte volle Antwort aus (Ursache für „paragraphCount fehlt“ bei 42-Zeilen-Rechnungen).
- **20.11.2026** – `paragraphCount` auch in `command_batch`-Ergebnissen und bei `type.setStyle`/`type.edit`; Qwen wertet weniger Formatläufe nach dem Speichern nicht mehr als Absatzverlust.
- **20.11.2026** – PhotoCraft: versteckte Arbeitsstände anderer Sitzungen im gemeinsamen Ergebnisordner nach 7 Tagen in den Papierkorb; fehlender Stand wird beim nächsten Auftrag übersprungen.
- **20.11.2026** – Dauerhafter PhotoCraft-Ergebnisordner mit pfadlosem Speichern früherer Ergebnisse und einer separaten Absatzzahl in `type.info`.
- **20.11.2026** – Eigener Pi-Modus für Programmieraufgaben im LLM-Chat mit Projektordner, lokalen Befehlen und Wiederaufnahme gespeicherter Chats. Hinweise zur Quellenkennzeichnung ergänzt und identische Suchwiederholungen begrenzt.
- **20.11.2026** – PhotoCraft gibt den absoluten Ergebnispfad zurück, fängt gleichnamige Vorlagen und Ergebnisse ab und prüft Textänderungen nach dem Wiederöffnen. Redundante relative Zielpräfixe werden entfernt.
- **20.11.2026** – CLI-Parametertests verwenden den Programmnamen aus dem installierten App-Bundle.
- **20.11.2026** – Datumsablauf mit anonymisierter Rechnungs-PSD geprüft. Schriftprüfung vor dem Bearbeiten und Ersatz innerhalb einzelner Schriftformatläufe ergänzt.
- **20.11.2026** – Systemweiter Schriftordner für PhotoCraft und der Formatverlust bei getrennten Änderungen über den Volltextersatz sind dokumentiert.
- **20.11.2026** – PhotoCraft übernimmt für Folgerechnungen die letzte fertige PSD als Kopie, ersetzt nur gleich lange Datumsstellen und vergleicht die gespeicherte Vorschau mit der Ausgangsdatei.
- **20.11.2026** – PhotoCraft legt gewünschte Ergebnis-Unterordner beim Speichern und Exportieren an. Der Chat wählt PSD-Ebenen bevorzugt per Name, ersetzt formatierte Textstellen gezielt und prüft Layout, Zeichenbereiche und fehlende Schriften.
- **20.11.2026** – PhotoCraft geprüft und verbessert: `doc_export_layers` frei, Prompt (Ebene über Lage bestimmen, Exporte gegenprüfen, nur Dateinamen, keine Testdateien, frühere Ergebnisse bei „alle Dateien“ auslassen), Ergebnisse auch aus Unterordnern, Sandbox mit echten Pfaden, Strata-Weiterleitung über Tailscale wenn LAN fehlt, klare Meldung beim Wächter-Abbruch.
- **20.11.2026** – PhotoCraft: `doc_close` freigeschaltet und im Prompt verlangt (viele Dateien nacheinander); harte 10-min-Grenze durch Wächter ersetzt (5 min ohne Ereignis / 60 min gesamt).
- **20.11.2026** – Anleitung zum Weitergeben mit Installation je Modell (Hugging-Face-Quellen, Größen, Quantisierung für 24 GB, Lizenz-Gebiete); Server-Skripte von bigki nach `server/` übernommen.
- **20.11.2026** – `share/make_zip.py` + `share/LIESMICH-ZUERST.md`: bereinigte ZIP zum Weitergeben (ohne Schlüssel, Adressen, Namen, Verlauf, Modelle), Anleitung für fremde Agenten und RTX 3090 (mit eigener Strata-Installation).
- **20.11.2026** – LLM-Chat nutzt die Fensterbreite (bis 1600 pt statt 820) und etwas größere Schrift (14,5 pt), größere Bildvorschau.
- **20.11.2026** – LLM-Chat: Vorschau für angehängte .md/.txt/.csv/.json; keine falsche Bildvorschau mehr bei reinen Textergebnissen.
- **20.11.2026** – LLM-Chat: Rückfragen wie bei Claude Code (Ja / Ja in diesem Chat / Ja immer hier je Programm / Nein mit Hinweis), Freigaben im Sicherheitsmenü zurücksetzbar.
- **20.11.2026** – LLM-Chat: Sicherheitsstufen Sandbox / Fragen / Alles erlauben für Dateien im Arbeitsordner (Rückfrage-Karte in der App, Pi-Erweiterung `pi-permissions.mjs`).
- **20.11.2026** – Strata auf 262.144 Token Kontext (nativ, Backup des Profils auf bigki); Auto-Compact-Grenze im Chat wählbar (Klick auf die Kontextanzeige), gilt auch für Pi.
- **20.11.2026** – LLM-Chat: `/compact [Schwerpunkt]` fasst den Verlauf sofort zusammen (Pi `compact` bzw. Zusammenfassung im normalen Chat).
- **20.11.2026** – LLM-Chat: Steuern während der Arbeit (Pi `steer`), Folgeprompt-Warteschlange, Verlauf der Schritte mit Denken, Stopp behält alles, Autospeichern mit „Temporär“-Schalter, Kopieren-Knopf; Pi hat volle Dateiwerkzeuge im Arbeitsordner (Sandbox ohne Netz und ohne Löschen).
- **20.11.2026** – LLM-Chat: Antworten werden als Markdown dargestellt (Tabellen, Listen, Überschriften, Code; derselbe Renderer wie die Übersicht in den Einstellungen).
- **20.11.2026** – LLM: Live-Anzeige von Strata (Prompt lesen/Schreiben, t/s, Kontext); `list_documents` liefert Änderungs-/Erstellungsdatum und Größe und kann rekursiv suchen.
- **20.11.2026** – LLM: Kontextanzeige und Auto-Compact (ab ~147k, letzte ~20k wörtlich; Pi mit denselben Werten); GPU-Sperre: beim Strata-Start behält der Broker alle drei Karten bis Strata antwortet (MI50-Sperre bleibt für Stratas Starter frei), Wartegrund nennt jetzt das blockierende Programm.
- **20.11.2026** – iPhone: App-Icon, wählbare automatische Downloads, typweiser Cache, erweiterte Regler, Werkzeuge, Whisper-Diktat über den Mac mini und gemeinsames Chat-Archiv.
- **20.11.2026** – LLM-Chat: gemerkter Arbeitsordner, immer sichtbar; PhotoCraft-Ergebnisse landen im Arbeitsordner (`PhotoCraft-Ergebnisse/<Zeit>`); Datei-Helfer nutzt das gebündelte Node statt Homebrew.
- **20.11.2026** – Optionale Websuche auf direkte Bing-Abfragen umgestellt. OrbStack entfällt.
- **20.11.2026** – Lokales Diktat im Mac-Chat: Mikrofonknopf, Whisper large-v3-turbo German über `whisper-cli` (nichts
  verlässt den Mac), Modell unter Application Support mit SHA-256-Prüfung; Auswahl per Vergleich mit Moonshine, Parakeet.
- **20.11.2026** – PhotoCraft-Modus mit Pi-RPC, Ordnerfreigabe oder einzelner Dokumentkopie, lokalen Vorschauen und Chat-Speicherung. Optionale Websuche über den eigenen SearXNG-Dienst. Der Strata-Leerlaufwächter berücksichtigt externe Clients.
- **20.11.2026** – Denkstufen für Qwen3.8 Flash Next in StudioPortal (macOS-App, iPhone-App, CLI, MCP, Gateway, Worker): `none` (Aus), `low` (Niedrig), `medium` (Mittel), `high` (Hoch) wird als `reasoning_effort` + `chat_template_kwargs` an Strata übergeben; Gedankengang (`reasoning`) wird live gestreamt und einklappbar über der Antwort angezeigt, Prompt-Processing-t/s steht mit in der Info-Zeile. Strata-Produktion auf bigki auf v0.2.16 `mtp1` (`20261120-v0216-mtp1/strata`, `STRATA_MTP_STAGE=1`, Split `17,33`, 140,0 / 89,7 t/s) umgestellt.
- **19.11.2026 (2)** – bigki aufgeräumt (≈380 GB frei → 434 GB frei / 53 % belegt): 43 alte Worker-Versionsordner, alte Blender-Test-Sitzungen und Figur-Testreste unter `~/.local/share/3d-modelle-app` sowie freigegebene Alt-Modelle außerhalb entfernt (offener Punkt aus Abschnitt 6 erledigt).
- **19.11.2026** – Privates GitHub-Repo `StudioPortal` als `origin`, vorher auf Secrets geprüft. README auf den heutigen Stand, AGENTS.md als Einstieg, CLAUDE.md verweist nur noch darauf.
- **18.11.2026** – Quellstand vom MacBook auf den Mac mini geholt, lokales Git-Repo. Neu: LLM-Chat (Strata, Qwen3.8
  Flash Next auf 3× MI50, Start bei Bedarf über die Warteschlange, Auto-Stopp nach 20 min, t/s unter jeder Antwort;
  CLI/MCP `llm`), iPhone-Dienst (`serve`, Tailscale serve, Port 8790) und iPhone-App (3.15). `setup_bigki.py` läuft
  auf dem Mac mini direkt. Standardtests (5.): Worker-LLM gegen einen nachgebauten Strata-Server, CLI-Parameter,
  Blender-Figurtest mit CMU-Clip.
- **17.11.2026 (11)** – Agentenweg vollständig: `guide`-Werkzeug (Bedienwissen der App aus denselben Daten), alle
  App-Regler als Parameter, `like`/`new_seed` = Übernehmen/Variieren für Bild, Musik, Video. In die App geholt:
  Omni-Figur („Figur mit Pose“) und Vergleichsleiste. Oberfläche: Ergebnis oben nur bei Auswahl (×/Esc, Start-Ansicht
  für Neues), Musik „Mit/Ohne Gesang“, Musik-Cover nach Beschreibung/Melodie, Bibliothek ohne Neuladen beim Wechsel,
  Vorschaubilder im Hintergrund, 3D-Vorschauen per Blender auf dem Mac, .glb in der Bibliothek. `bvh_laden`: Hüfthöhe,
  Startpunkt, Bodenkontakt (inkl. Neigung) und Hände bei CMU-BVH behoben (echter Test mit CMU 02_01).
- **17.11.2026 (10)** – Bild, Musik und Video neu aufgebaut: Eingabe unten mit Options-Pillen, Verlauf als Feed mit
  Infos sowie „Übernehmen“/„Variieren“. Bibliothek-Raster rutscht nicht mehr unter die Seitenleiste. UniRig-Knochen
  bekommen sprechende Namen. Echte Tests bestanden: SSH-Abbruch nach 10 s → automatisch abgeholt; hängende Vorschau
  (siehe 3.9).
- **17.11.2026 (9)** – Codex-Praxistest eingearbeitet: Retargeting-Fehler in `bvh_laden` behoben (Becken kippte um 180°,
  jetzt Kopf im neutralen Bild 62 cm über der Hüfte, Selbstprüfung in der Antwort); Neustart-Hinweis nennt den echten
  Grund (`ende.json`); neue Vergleichsleiste `compare_images` mit Detailausschnitten; Render-Begleitdateien mit
  Kamera/Auflösung/Samples/Quelle.
- **17.11.2026 (8)** – Agenten-Rückmeldung Blender umgesetzt: Abholschein für alle Sitzungsaufrufe (nichts geht bei
  Verbindungsabbruch verloren, `blender_session action=abholen`), hängende Vorschau wird mit Grund beendet und neu
  gestartet, eigene Funktionen/Variablen überstehen Neustarts, `gewichte_uebertragen modus='naechster'` (Standard für
  Kleider), `figur.handy_griff`, `figur.schnell_posieren`, `figur.bvh_laden` (Mixamo/BVH-Retargeting).
- **17.11.2026 (7)** – Optimierungs-Infos nur noch in der Übersicht (nicht mehr in den Werkzeugen); Rechner zeigt, wer jede
  Karte nutzt, und alle Blender-Sitzungen (auch für Agenten in `status`); Video standardmäßig 6 Schritte (gemessen 462 s
  statt 280 s, deutlich schärfer); `figur.auto_rig` (UniRig auf CPU) + Rechtsklick im Blender-Tab; Bibliothek lädt
  3D-Modelle nachgelagert; Build mit Apple-Development-Signatur; kürzere Voreinstellungs-Texte; neuestes Ergebnis ist
  beim Öffnen ausgewählt.
- **17.11.2026 (6)** – „Porträt“: lcm mit Rauschplan 1,1→0,9 (Test 16 MP); Bildteil der Optimierung abgeschlossen.
- **17.11.2026 (5)** – Speed-LoRA (pDMD, 2 Schritte) für H3 Image, Voreinstellung „Schnell“ = 4 MP in ~1¼ min; Worker
  ausgerollt ohne Mac mini über `setup_bigki.py --files-only --via-session` (App-Schlüssel → Worker → Blender-Sitzung).
- **17.11.2026 (4)** – H3-Image-Einstellungen mit Internet-Quellen abgeglichen (3.10), Test 16 MP euler vs. lcm, „Bearbeiten“
  4 MP, neue Tipps (80–150 Wörter, mehrere Seeds, Bearbeiten). Musik gemessen: 3 Skizzen 284 s, volle Qualität 379 s.
- **17.11.2026 (3)** – Voreinstellungen + ⓘ-Erklärungen + Vorher/Jetzt-Diagramme für Bilder (1–16 MP, native Größen,
  Testreihe), Musik (Skizzen/voll/Stimme/Instrumental) und Video (17n+5-Raster, Option 6 Schritte); neuer Tab Blender;
  Übersicht zeigt je Funktion Weg, Normal und „Auf der MI50 angepasst“. Blender: Speicherwächter mit Absturzgrund,
  Autosave nach jedem Aufruf, `look` meldet `im_bild`/Sichtbarkeitsfalle/gleiches Bild, Ausreißer- und Größenprüfung
  vor Remesh, lange Aufrufe als Job (> 50 s), Skriptdateien laden, `status` ohne Warten. Omni: FlashVDM-Dekodierung
  (413 s statt > 30 min). `create_image`/`create_video` mit `preset`.
- **17.11.2026 (2)** – Agenten-Feedback: Render mit Abholschein (übersteht Tailscale-Hänger), `abbrechen` ausdrücklich,
  `get_job wait`, NaN-sichere Antworten, Bildleiste bei mehreren Kameras, `look` mit Zoom/Ausschnitt und Ablage mit
  Namen, `check` mit Dicke/Lochrändern/Löschen loser Teile, `helfer.*`, `figur.kleid_anlegen`/`kleid_simulieren`.
  Omni: DINOv2-Konfiguration nachgeladen, Attention-Fallback, Protokoll je Auftrag. Bild-Generator heißt richtig
  „MiniMax H3 Image“ (stand fälschlich HunyuanImage 3). Einstellungen → Übersicht neu: klickbares Bild
  (Macs → Tailscale → bigki → 3× MI50) und Karten je Funktion; die Erklärung ist der passende Abschnitt dieser Datei
  (3.x), darunter der ganze Text. Neue Abschnitte 3.10–3.13 (Bilder, Musik, Video, 3D) mit „Optimiert“/„Noch offen“.
- **17.11.2026** – Blender: Ansichten-Raster, Fokus, Einfärben, Prüfungen in Zahlen, Zwischenstände, Werkzeugdatei,
  Neustart-Hinweis, Öffnen/Speichern direkt auf bigki (mit Überschreibschutz), Render mit mehreren Kameras.
  Figuren-Bausteine (`figur.*`), Hunyuan3D-Omni (`figure_3d`), Videoseite stürzt nicht mehr ab (AVPlayerView),
  Videozeit ohne Wartezeit, 3D/Video auf dem Mac mini nach stori. Diese Datei angelegt.
