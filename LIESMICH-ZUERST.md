# StudioPortal – zum Nachbauen auf deinem eigenen Rechner

Dieses Repository enthält den kompletten Quellcode von StudioPortal, aber **keine Schlüssel, keine Adressen und keine
Modelle**. Es ist für einen Coding-Agenten (Claude Code, Codex …) geschrieben. Gib ihm diesen Auftrag:
„Lies LIESMICH-ZUERST.md und ARCHITEKTUR.md und richte StudioPortal für meinen Rechner ein.“

Zielaufbau, auf den diese Anleitung zugeschnitten ist:
- **MacBook** mit der App.
- **Linux-PC** mit **RTX 3090 (24 GB)** und **64 GB RAM** im selben WLAN/LAN, zusätzlich per Tailscale erreichbar.
- **Strata** mit Qwen3.8 auf dem PC (eigene Quantisierung).

## 1. Was StudioPortal ist

StudioPortal ist eine macOS-App, dazu eine Kommandozeile und ein MCP-Server für Agenten. Sie erzeugt Bilder, Musik,
Videos mit Ton, 3D-Modelle und Figuren, bietet einen LLM-Chat mit Agenten-Modus und steuert eine Blender-Sitzung.

Gerechnet wird **nicht auf dem Mac**, sondern auf dem Linux-PC. Der Mac schickt jeden Auftrag über **eine
SSH-Verbindung** an `src/bigki_worker.py`. Der Worker holt sich die Karte über `src/gpu_broker.py` und startet das
passende Programm.

`ARCHITEKTUR.md` beschreibt jedes Teil. Im Original heißt der GPU-Rechner **bigki** und hat **3× AMD MI50 (je 32 GB)**.
Bei jeder Funktion steht dort zweierlei:
- „**Normal**“: so läuft es üblicherweise, meist mit CUDA.
- „**Auf der MI50 angepasst**“: Sonderwege für die alten AMD-Karten (eigener ROCm-Build, Aufteilung auf drei Karten,
  Token-Split).

**Mit einer NVIDIA-Karte gilt fast immer „Normal“**, die MI50-Sonderwege brauchst du nicht.

## 2. Überblick: was wohin kommt

| Wo | Was |
|---|---|
| MacBook | App (`./build.sh`), Xcode Command Line Tools, Node ≥ 18, Tailscale, Blender (Import, Vorschaubilder), `whisper-cpp` (Diktat), Pi (Agenten-Modus im Chat) |
| Linux-PC | Worker + Broker unter `~/.local/share/3d-modelle-app/<version>/`, NVIDIA-Treiber + CUDA-Toolkit, `git`, `cmake`, `uv` oder `python3-venv`, `hf` (`pip install huggingface_hub`), Blender 5.x, Strata, die Modelle aus Abschnitt 4 |

Für die Modelle allein brauchst du **rund 100 GB** auf der SSD, das Strata-Modell kommt dazu.

## 3. Mac einrichten

1. Installieren:
   ```bash
   xcode-select --install
   brew install node whisper-cpp
   ```
   Dazu Tailscale und Blender (blender.org) nach `/Applications`.
2. Bauen und installieren:
   ```bash
   ./build.sh
   ```
   Danach `build/StudioPortal.app` nach `~/Applications/` kopieren. Kommandozeile: `ln -s ~/Applications/StudioPortal.app/Contents/MacOS/StudioPortal ~/.local/bin/studioportal`.
3. **Diktat**: Das Modell lädt die App beim ersten Diktat selbst.
   - Modell: Whisper large-v3-turbo German, ggml q5_0, 574 MB, Apache-2.0.
   - Es läuft nur auf dem Mac (Metal), nicht auf dem PC.
   - Von Hand: Hugging Face `cstr/whisper-large-v3-turbo-german-ggml`, Datei `ggml-model-q5_0.bin`, ablegen als
     `~/Library/Application Support/StudioPortal/Modelle/whisper-turbo-de-q5_0.bin`.
4. **SSH-Schlüssel**: `ssh-keygen -t ed25519 -f ~/.ssh/3d-modelle-bigki`.
   - Der Schlüssel wird auf dem PC mit `from="<Mac-IP>",restrict,command="python3 …/worker.py"` eingetragen. Er
     kann dann **nur** den Worker starten (Abschnitt 3.3).
   - `setup_bigki.py` macht das. Im Original geht es über einen Admin-Zugang vom Mac mini aus, das an deinen Weg
     anpassen.
   - Für den Anfang reicht es, die Dateien aus `setup_bigki.py` (Liste `files`) von Hand nach
     `~/.local/share/3d-modelle-app/<version>/` zu kopieren und den Schlüssel selbst einzutragen.
5. **Pi für den Agenten-Modus im Chat**: Pi nach `~/.local/bin/pi` installieren, es läuft mit Node aus Homebrew. In
   `~/.pi/agent/models.json` einen Provider `strata` anlegen (siehe 5.6).
6. **PhotoCraft** (`/Applications/PhotoCraft.app`) ist eine eigene App und nicht Teil davon. Ohne sie fehlt im Chat nur
   das PhotoCraft-Werkzeug.

## 4. Modelle auf dem Linux-PC installieren

Pfade wie im Original, damit der Worker sie findet. Andere Orte sind möglich, dann die Konstanten oben in
`src/bigki_worker.py` ändern: `H3`, `SD_CLI`, `MUSIC`, `VIDEO`, `ROOT`, `FIGUR`, `BLENDER_MI50`, `STRATA_*`.
Downloads mit `hf download <repo> <datei> --local-dir <ordner>`. Abbrüche setzt `hf` beim nächsten Aufruf fort.

### 4.1 Programm stable-diffusion.cpp (für Bild und Video)

Upstream `https://github.com/leejet/stable-diffusion.cpp` kann MiniMax H3 (Bild und Video). Für die Bilder nutzt das
Original es **unverändert**. Der Video-Build hat nur MI50-Patches (Token-Split über zwei Karten), die du nicht brauchst.

```bash
git clone --recursive https://github.com/leejet/stable-diffusion.cpp ~/sdcpp-h3image/src
cd ~/sdcpp-h3image/src && cmake -B build -DSD_CUDA=ON && cmake --build build --config Release -j
```

- Im Worker `SD_CLI` auf `~/sdcpp-h3image/src/build/bin/sd-cli` setzen.
- Für Video denselben Build nehmen: `VIDEO / 'src' / 'build-hip' / 'bin' / 'sd-cli'` an zwei Stellen im Worker
  anpassen, `src3` (Drei-Karten-Build) entfällt.

### 4.2 Bild: MiniMax H3 Image

| Teil | Hugging Face | Datei | Größe |
|---|---|---|---|
| Bildmodell (DiT) | `unsloth/MiniMax-H3-Image-GGUF` | `minimax_h3_image_pruned-Q6_K.gguf` (Original: `-Q8_0`, 22 GB, passt nicht in 24 GB) | 16,6 GB |
| VAE | `Comfy-Org/MiniMax-H3-Image` | `vae/minimax_h3_image_vae_fp16.safetensors` | 1,2 GB |
| Textkodierer (auch für Video) | `leejet/MiniMax-H3-GGUF` | `qwen3vl_32b_minimax_h3-Q4_K_M.gguf` | 18,2 GB |

- Ablage: DiT und `vae/` nach `~/h3-image/models/`, den Textkodierer nach `~/sdcpp-mi50/models/`.
- Im Worker `H3_MODELS` auf diese Dateinamen ändern. Das Original nutzt einen selbst konvertierten Q8-Textkodierer
  (`…-from-nvfp4-Q8_0.gguf`); Q4_K_M ist die fertige Variante.
- Reicht der Speicher nicht: `Q5_K_M` (14,6 GB) oder `UD-Q5_K_XL` (15,5 GB).
- **Platzierung** in `h3_command` (Original: `--backend te=ROCm0,diffusion=ROCm0&ROCm1&ROCm2,vae=ROCm2`,
  `--split-mode layer`):
  - Für eine Karte alles auf die 3090. Den Gerätenamen (`CUDA0`) zeigt `sd-cli -v` beim Start.
  - Den Textkodierer nicht dauerhaft auf die Karte legen, wie im Original `--params-backend te=disk`. Mit 64 GB RAM
    geht auch der RAM.
  - `--split-mode layer` weglassen und `--vae-tiling` anlassen.
- Werte (6 Schritte, CFG 1, euler, `--sigmas minimax-h3-image`) bleiben gleich.

### 4.3 Video mit Ton: MiniMax H3 Video (FL2VA) + Turbo-4-Schritte

| Teil | Hugging Face | Datei | Größe |
|---|---|---|---|
| Videomodell (DiT) | `leejet/MiniMax-H3-GGUF` | `minimax_h3_fl2va_pruned-Q4_K_M.gguf` | 11,4 GB |
| Turbo-LoRA (4 Schritte) | `Comfy-Org/MiniMax-H3` | `loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors` | 2,0 GB |
| Video-VAE | `Comfy-Org/MiniMax-H3` | `vae/minimax_h3_video_vae_fp16.safetensors` | 5,2 GB |
| Audio-VAE | `Comfy-Org/MiniMax-H3` | `vae/minimax_h3_audio_vae_fp32.safetensors` | 0,6 GB |
| Textkodierer | wie bei Bild | `qwen3vl_32b_minimax_h3-Q4_K_M.gguf` | – |

- **LoRA einrechnen**: Das Original hat die Turbo-LoRA einmal eingerechnet und als `…-turbo4-Q6_K.gguf` gespeichert:
  ```bash
  sd-cli -M convert --diffusion-model minimax_h3_fl2va_pruned-Q4_K_M.gguf --lora <turbo-lora> \
         --tensor-type-rules "(qkv_proj|out_proj|fc1|fc2)\.weight=q6_K"
  ```
  Eingabe, Ausgabe und Schreibweise der LoRA genau nach `sd-cli --help` deiner Version. Die eingerechnete Q6_K-Datei
  ist größer als Q4_K_M (16,6 GB). Passt sie mit Aktivierungen nicht in 24 GB, dann Q4_K_M behalten und die LoRA zur
  Laufzeit laden.
- Im Worker `VIDEO_MODELS` auf deine Dateien setzen, den Audio-VAE-Pfad auf deinen Ort ändern (im Original
  `~/.local/share/paiton/…`).
- `video_placement` gibt eine Zwei-Karten-Platzierung (`ROCm0/1`) zurück. Für eine Karte alles auf `CUDA0`, statt
  `--auto-fit off` lieber `--auto-fit`, und `SD_H3_TOKEN_SPLIT` weglassen.
- Werte bleiben gleich: euler, simple, Shift 6, CFG 1, Länge im 17n+5-Raster.

### 4.4 Musik: MiniMax Music 3 mit `minimaxmusic.cpp`

```bash
git clone https://github.com/ServeurpersoCom/minimaxmusic.cpp ~/minimaxmusic.cpp
cd ~/minimaxmusic.cpp && ./buildcuda.sh
./models.sh    # Q8_0-Satz aus Serveurperso/MiniMax-Music3-GGUF
```

- Der Q8_0-Satz sind gut 12,8 GB in `models/`: Sprachmodell 9,1, Transformer 2,6, Tiefen-Decoder 0,7,
  Condition-Encoder 0,1 und Vocoder 0,3 GB.
- Passt gut auf die 3090. Bei Bedarf `./models.sh --quant Q6_K`.
- Im Worker `MUSIC / 'build-hip906' / 'mm-synth'` auf deinen CUDA-Build ändern; den Ort zeigt `buildcuda.sh`. Die
  Stelle kommt zweimal vor (Start und `ready`-Meldung).
- Ausgaben: `~/music3/output/studioportal` (`MUSIC_JOBS`).
- Die Vorlagen (Beispiele) liest die App aus `tools/webui/example/*.json`, die bringt `minimaxmusic.cpp` mit.

### 4.5 3D aus 1–4 Ansichten: Hunyuan3D-2mv

```bash
mkdir -p ~/hunyuan3d-2mv && cd ~/hunyuan3d-2mv
git clone https://github.com/Tencent-Hunyuan/Hunyuan3D-2 src
cp ./server/hunyuan3d-2mv/*.py .          # generate.py, decode_latents.py, project_colors.py
uv venv .venv --python 3.11 && uv pip install --python .venv/bin/python torch --index-url https://download.pytorch.org/whl/cu128
uv pip install --python .venv/bin/python -r src/requirements.txt rembg onnxruntime trimesh pymeshlab opencv-python scipy safetensors
hf download tencent/Hunyuan3D-2mv --include "hunyuan3d-dit-v2-mv/*" "hunyuan3d-dit-v2-mv-turbo/*" --local-dir models
```

- Gebraucht werden je Ordner `config.yaml` und `model.fp16.safetensors` (je 4,9 GB).
- Das Hintergrund-Entfernen (rembg, `isnet-general-use`) lädt sich beim ersten Lauf nach `models/rembg/`
  (`U2NET_HOME`).
- Die drei Skripte stammen aus dem Original und nutzen `torch.cuda`, das läuft auf NVIDIA genauso.
- Der Worker ruft `decode_latents.py --gpus 3` auf, für die 3090 auf `--gpus 1` ändern.

### 4.6 Figuren: Hunyuan3D-Omni, DINOv2, UniRig

Im Ordner `server/figur/` liegen die Original-Skripte: `download.sh`, `omni-setup.sh`, `unirig-setup.sh`, dazu der
CPU-Ersatz `unirig-shims/flash_attn` und `unirig-configs/cpu_skin_transform.yaml`.

```bash
mkdir -p ~/.local/share/3d-modelle-app/figur && cp -R ./server/figur/* ~/.local/share/3d-modelle-app/figur/
cd ~/.local/share/3d-modelle-app/figur && ./download.sh
```

`download.sh` holt:
- `Tencent-Hunyuan/Hunyuan3D-Omni` (Code) und `tencent/Hunyuan3D-Omni` ohne `pytorch_model_ema.bin`: Modell 12,2 GB,
  VAE 1,3 GB.
- `VAST-AI/UniRig` (Skelett 1,4 GB, Haut 4,4 GB) und `facebook/dinov2-large`.

Danach:
- **Omni-venv**: Python-venv `omni-venv` mit PyTorch für CUDA anlegen (das Original leiht sich Torch aus der 2mv-venv),
  dann `omni-setup.sh`.
- `src/omni_figur.py` biegt Attention auf den Mathe-Pfad um, weil die MI50 keine Flash-Attention hat. Auf der 3090
  kann das raus, es schadet aber nicht.
- **UniRig** läuft absichtlich auf der **CPU**, `unirig-setup.sh` richtet das ein. `cpu_skin_transform.yaml` nach
  `unirig/configs/transform/` kopieren. Mit CUDA ginge es schneller, nötig ist es nicht.

### 4.7 Blender auf dem PC (Sitzung, Render)

- **Blender**: Blender 5.x für Linux von blender.org entpacken und verlinken:
  `ln -s <blender>/blender ~/.local/share/3d-modelle-app/bin/studioportal-blender`.
- **MPFB-Erweiterung** (für `figur.mensch`, Menschen): in genau diesem Blender aus der Blender-Erweiterungsplattform
  installieren. Das Modul muss `bl_ext.user_default.mpfb` heißen.
- **Python-Zusätze für Blender** (scipy, libigl, robust_laplacian) für Blenders eigene Python-Version installieren:
  ```bash
  <blenders python> -m pip install --target ~/.local/share/3d-modelle-app/pylib/py3XX scipy libigl robust_laplacian
  ```
  Ordnername `py313` bei Python 3.13.
- **Render-Skripte**: Ordner `BLENDER_MI50` (Original `~/Schreibtisch/blender-mi50`) mit zwei Dateien anlegen.
  - `run.sh` mit genau dieser Zeile, die der Worker ausliest:
    `B="${BLENDER:-/pfad/zu/blender}"`, danach `exec "$B" "$@"`. Die ROCm-Zeilen des Originals entfallen.
  - `anim_setup.py` aus `server/blender/`, darin `'HIP'` durch `'OPTIX'` (oder `'CUDA'`) ersetzen. Im Worker
    `BENCH_DEV: 'HIP'` ebenso, an drei Stellen.
- Die Sitzung zeichnet im Original auf der Intel-iGPU (`IGPU_ARGS`, `IGPU_ENV`), damit die MI50 frei bleiben. Ohne
  Intel-iGPU diese beiden leeren.

### 4.8 Sprachmodell: Strata

Strata und das Qwen3.8-Modell bringst du selbst mit. Wie StudioPortal Strata startet, steht in 5.6.

### Lizenzen – bitte vorher lesen

Jedes Modell hat seine eigene Lizenz, die Hugging-Face-Seite jeweils ansehen:
- **MiniMax H3 (Video) und H3 Image**: Die Community-Lizenz schließt ausdrücklich die **EU, Großbritannien, Südkorea
  und die USA** aus.
- **Hunyuan3D-2mv und Hunyuan3D-Omni**: Die Lizenz gilt ausdrücklich **nicht in der EU, Großbritannien und Südkorea**.
- **MiniMax Music 3**: eigene Community-Lizenz mit Bedingungen für kommerzielle Nutzung.
- **UniRig**: MIT. **DINOv2** und **Whisper Turbo DE**: Apache-2.0.
- **`vendor/sfrip`** (Sketchfab-Import): MIT. Ob du Sketchfab-Modelle so herunterladen darfst, hängt vom jeweiligen
  Modell ab.

## 5. Platzhalter und Anpassungen im Code

### 5.1 Platzhalter

Die echten Adressen und Namen des Originals sind durch diese Platzhalter ersetzt:

| Platzhalter | Bedeutung | Wo vor allem |
|---|---|---|
| `GPU-SERVER-IP` | Tailscale-Adresse des PCs (unterwegs) | `src/H3Backend.swift`, `src/from_images.mjs`, `setup_bigki.py`, `vendor-h3-src/Sources/Backend.swift` |
| `GPU-SERVER-LAN-IP` | WLAN/LAN-Adresse des PCs (zu Hause, schneller) | `src/PhotoCraft.swift`, `src/StrataLive.swift`, `tests/run_blender_tests.sh` |
| `GPU-SERVER-HOSTKEY` | SSH-Host-Key des PCs (`ssh-keyscan`) | `vendor-h3-src/Sources/Backend.swift` |
| `MAC-1-IP`, `MAC-2-IP` | Adressen der Macs (für `from=` im SSH-Schlüssel) | `setup_bigki.py`, `ARCHITEKTUR.md` |
| `DEIN-MAC`, `DEIN-MAC.DEIN-TAILNET.ts.net` | zweiter Mac für den Sync, iPhone-Dienst; mit nur einem MacBook unwichtig | `src/Sync.swift`, `ios/StudioPortal/API.swift` |
| `du@…` | dein Benutzername | `src/Sync.swift`, `setup_bigki.py` |
| `local.beispiel…`, `de.beispiel…` | Bundle-IDs; nimm eigene | `src/Info.plist`, `src/Gateway.swift`, `ios/project.yml`, `vendor-h3-src/` |
| `bigki-admin-config`, `bigki-admin-key` | Namen von Admin-SSH-Dateien (nicht der App-Schlüssel) | `setup_bigki.py`, `tests/run_blender_tests.sh` |

Der Benutzername auf dem PC heißt im Code `bigki`, z. B. `bigki@GPU-SERVER-IP`; ersetze ihn durch deinen. Zum Finden:

```bash
grep -rn "GPU-SERVER\|DEIN-MAC\|beispiel\|bigki@" .
```

### 5.2 Karten erkennen (`src/gpu_broker.py`)

- Der Broker liest AMD-Karten aus `/sys/class/kfd` und `/sys/class/drm/.../hwmon`: Temperatur, Speicher und fremde
  Prozesse.
- Für NVIDIA auf `nvidia-smi --query-gpu=index,temperature.gpu,memory.used,memory.total --format=csv` und
  `--query-compute-apps` (fremde Prozesse) umstellen.
- Ein laufendes Strata gilt als fremder Prozess. Dann vergibt der Broker die Karte nicht, und Bild/Video warten, bis
  Strata stoppt (20 min nach der letzten Anfrage).
- Die Testvariante (`FAKE`) nimmt fest drei Karten an (`range(3)`), auf eine ändern.

### 5.3 Kartenauswahl (`bigki_worker.py`)

- `ROCR_VISIBLE_DEVICES` und `HIP_VISIBLE_DEVICES` werden zu `CUDA_VISIBLE_DEVICES`.
- `ROCM` (eigener gfx906-Build) und `HSA_OVERRIDE_GFX_VERSION` fallen weg.
- Überall, wo mehr als eine Karte verlangt wird (`acquire(3, …)`, `cards` bis 3, `--gpus 3`), auf 1 begrenzen.

### 5.4 Wärme und Schutz

Die Grenzen 92 °C (Karte vergeben) und 65 °C (Musik/Video starten) sowie die `mi50-*`-Dienste gehören zum Original.
Für die 3090 eigene Grenzen über `nvidia-smi` setzen oder die Prüfung abschalten.

### 5.5 Fremde Sperren

`~/mi50-phase0/mi50-experiment.lock` und die `paiton`-Sperre (`~/.local/share/paiton/gpu-coordination/gpu.lock`) gibt
es nur auf dem Original-Rechner. Entfernen oder durch eine eigene ersetzen.

### 5.6 Strata

Gemeint ist `operation: llm` im Worker (Abschnitt 3.14 in ARCHITEKTUR.md). StudioPortal startet und stoppt nur deine
Strata-Installation und spricht ihre OpenAI-API an. Anzupassen sind:
- Im Worker:
  - `STRATA_PROFILE`: dein Profil-JSON; daraus liest er `port`, `api_key`, `model_name` und `--max-context`.
  - `STRATA_START`: dein Startskript, wird mit `--start` aufgerufen.
  - `STRATA_UNIT`: deine systemd-User-Unit (Original `mi50-strata.service`).
- `broker.acquire(3, …)` in `llm_start` holt drei Karten, für die 3090 auf `1`.
- Auf dem Mac `~/.pi/agent/models.json` mit einem Provider `strata`:
  - `baseUrl` = `http://GPU-SERVER-LAN-IP:8080/v1`; genau dieser Wert wird in `src/PhotoCraft.swift` geprüft.
  - `apiKey` = Strata-Key, dazu das Modell mit `id` und `contextWindow`.
  - Den Key liest die App auch für die Live-Anzeige (`src/StrataLive.swift`, Port 8080). Der Key gehört nie ins Repo.
- **Kontext**: Grundwert 262.144 Token. Die Kontextgröße im Profil an deine Quantisierung und die 24 GB anpassen;
  die Auto-Compact-Grenze stellt man in der App ein.

## 6. Reihenfolge, bauen, prüfen

Diese Reihenfolge hat sich bewährt:
1. Mac einrichten (Abschnitt 3).
2. Worker und Schlüssel auf dem PC einrichten.
3. Im MCP `status` aufrufen: Ist die Karte sichtbar?
4. Zuerst Musik (4.4) und 3D (4.5).
5. Dann Bild, Video, Figuren, Blender und Strata.

Tests ohne GPU:

```bash
python3 -I tests/test_worker.py    # Worker + Broker auf einem Fake-Server, ~30 s
python3 -I tests/test_agent.py
```

`studioportal help` zeigt die Kommandozeile, `studioportal mcp` ist der MCP-Server für deinen Agenten. Die Regeln in
`ARCHITEKTUR.md` Abschnitt 4 gelten auch bei dir: fremde Prozesse nie anfassen, nur eigene Dateien auf dem Server,
keine Schlüssel ins Repo.
