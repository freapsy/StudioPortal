# StudioPortal

Native **macOS-App (SwiftUI)**, **iOS-Companion-App**, **CLI (`studioportal`)** und **MCP-Server** zur Orchestrierung lokaler und hybrider KI-Workflows auf einem dedizierten Linux-GPU-Server.

> **Hinweis zum Setup:** Die Original-Installation laeuft auf einem Linux-Server mit **3x AMD Instinct MI50 (je 32 GB VRAM, ROCm `gfx906`)**. Fuer den Nachbau auf einer einzelnen NVIDIA-GPU (z. B. **RTX 3090 mit 24 GB VRAM / CUDA**) liegt die komplette Schritt-fuer-Schritt-Anleitung in [`LIESMICH-ZUERST.md`](LIESMICH-ZUERST.md).

---

## Funktionsuebersicht

| Bereich | Beschreibung |
|---|---|
| **Bildgenerierung & Bearbeitung** | Text-zu-Bild (1 bis 16 MP) und Multi-Referenz-Bildbearbeitung via `stable-diffusion.cpp` (MiniMax H3 Image) |
| **Video mit Ton** | Bild-/Text-zu-Video mit synchroner Tonspur (MiniMax H3 FL2VA, 4-Schritt-Turbo-LoRA) |
| **Musik** | Gesangs- und Instrumental-Tracks ueber `minimaxmusic.cpp` (MiniMax Music 3) |
| **3D & Figuren** | 3D-Rekonstruktion aus 1 bis 4 Ansichten (Hunyuan3D-2mv), Figuren mit Pose (Hunyuan3D-Omni), Auto-Rigging (UniRig), BVH-Retargeting und Blender-5.x-Live-Sitzung |
| **LLM-Chat & Coding-Agent** | Lokales LLM ueber Strata (Qwen3.8 Flash), Pi-Agentenmodus mit macOS-Sandbox, Arbeitsordner-Verwaltung, Auto-Compaction und lokalem Whisper-Diktat (Metal) |
| **Sprache & Echtzeit-Telefon-Agent** | Lokale Sprachsynthese (Fish Audio Drama 3 V2, Qwen3-TTS, Nemotron ASR, Smart Turn) sowie **LiveKit Agents** (WebRTC-AEC, umschaltbar zwischen 100 % Lokal, Hybrid und Cloud) |
| **CLI, MCP & iOS-App** | Vollstaendige Steuerung ueber `studioportal <befehl>`, MCP-Server (`studioportal mcp`) fuer Coding-Agenten sowie eigene SwiftUI-iPhone-App ueber Tailscale |

---

## Architektur im Ueberblick

```text
macOS App (SwiftUI) / CLI / MCP / iOS App
        │
        │  SSH (restriktiver Key, JSONL-Protokoll)
        ▼
Linux GPU-Server (src/bigki_worker.py + src/gpu_broker.py)
        ├── GPU-Scheduler & Warteschlange (Temperatur-/Speicher-Schutz, Vorrang fuer fremde Jobs)
        ├── stable-diffusion.cpp (Bild & Video)
        ├── minimaxmusic.cpp (Musik)
        ├── Hunyuan3D-2mv / Hunyuan3D-Omni / UniRig / Blender 5.x (3D & Figuren)
        ├── Strata (LLM-Server, OpenAI-kompatible API)
        └── audio.cpp (Drama 3 / Qwen3-TTS / Nemotron ASR / Smart Turn) + LiveKit Agents
```

Alle Details zu Modulen, Messwerten, Tests und Design-Entscheidungen stehen in [`ARCHITEKTUR.md`](ARCHITEKTUR.md).

---

## Schnellstart (macOS + NVIDIA RTX 3090 / CUDA)

Die vollstaendige Anleitung fuer eine einzelne **RTX 3090 (24 GB)** inkl. aller Hugging-Face-Modelle, Quantisierungen, Platzhalter-Tabelle und Anpassungen von ROCm auf CUDA befindet sich in **[`LIESMICH-ZUERST.md`](LIESMICH-ZUERST.md)**.

Kurzfassung fuer den Mac-Client:

```bash
xcode-select --install
brew install node whisper-cpp
./build.sh
```

Danach `build/StudioPortal.app` nach `~/Applications/` kopieren und die Platzhalter (`GPU-SERVER-IP`, `GPU-SERVER-LAN-IP`, `local.beispiel`, usw.) gemaess [`LIESMICH-ZUERST.md`](LIESMICH-ZUERST.md#5-platzhalter-und-anpassungen-im-code) an den eigenen Server anpassen.

---

## Projektstruktur

| Pfad | Inhalt |
|---|---|
| `src/*.swift` | macOS-App, CLI, MCP-Server, LiveKit-Integration, iOS-Gateway |
| `src/*.py` | GPU-Worker, GPU-Broker, Blender-Sitzung, LiveKit-Voice-Agent & Web-Bridge |
| `ios/` | SwiftUI-Companion-App fuer iPhone (`xcodegen`) |
| `server/` | Server-Skripte fuer Hunyuan3D-2mv, Hunyuan3D-Omni, UniRig und Blender-Render |
| `tests/` | Automatisierte Unit- und Integrationstests (laufen ohne GPU gegen Fake-Server) |
| `vendor/` | Drittanbieter-Komponenten inkl. Lizenztexten (`sfrip`, MIT) |
| `LIESMICH-ZUERST.md` | Komplettanleitung fuer den Nachbau auf eigener Hardware (RTX 3090 / CUDA) |
| `ARCHITEKTUR.md` | Vollstaendige Systemarchitektur, Benchmarks und Aenderungsprotokoll |

---

## Tests (ohne GPU lauffaehig)

```bash
python3 -m unittest discover -s tests -v
```

---

## Sicherheit & Privatsphaere

Dieses oeffentliche Repository enthaelt **keinerlei API-Keys, SSH-Schluessel, private IP-Adressen, Hostnamen oder Modellgewichte**. Alle Zugangsdaten werden zur Laufzeit ausschliesslich lokal unter `~/Library/Application Support/StudioPortal/` (`chmod 600`) gespeichert.

## Lizenzhinweise

Der eigene Code dieses Repositories dient als Portfolio- und Referenzprojekt. Drittanbieter-Modelle (MiniMax H3, MiniMax Music 3, Hunyuan3D, Fish Audio Drama 3, Whisper, UniRig, DINOv2) unterliegen jeweils ihren eigenen Lizenzen (Details in [`LIESMICH-ZUERST.md`](LIESMICH-ZUERST.md#lizenzen--bitte-vorher-lesen) und [`ARCHITEKTUR.md`](ARCHITEKTUR.md#4-regeln-die-immer-gelten)).
