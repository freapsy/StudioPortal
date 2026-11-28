#!/usr/bin/env python3
"""Tiny local HTTP server (127.0.0.1:7891) for StudioPortal's embedded LiveKit WebRTC call UI.

- Serves the dark-mode macOS-native WebRTC UI (`GET /`) and local `livekit-client.umd.min.js`.
- Issues signed dev JWT tokens (`POST /api/token`) for local `livekit-server --dev` (ws://127.0.0.1:7880).
- Stores & reads the active call briefing/profile config (`POST /api/config`, `GET /api/config`).
"""
from __future__ import annotations

import asyncio
import json
import os
import time
import urllib.request
from pathlib import Path

from aiohttp import web
from livekit import api

SUPPORT_DIR = Path.home() / 'Library' / 'Application Support' / 'StudioPortal'
WEB_DIR = SUPPORT_DIR / 'livekit-web'
CONFIG_PATH = SUPPORT_DIR / 'livekit-call-config.json'

LK_URL = os.environ.get('LIVEKIT_URL', 'ws://127.0.0.1:7880')
LK_HTTP_URL = LK_URL.replace('ws://', 'http://').replace('wss://', 'https://')
LK_KEY = os.environ.get('LIVEKIT_API_KEY', 'devkey')
LK_SECRET = os.environ.get('LIVEKIT_API_SECRET', 'secret')
BRIDGE_PORT = int(os.environ.get('STUDIOPORTAL_LIVEKIT_UI_PORT', '7891'))

HTML_PAGE = r"""<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>StudioPortal · LiveKit Telefon-Agent</title>
<style>
  :root {
    --bg: #1c1c1e;
    --panel: #262629;
    --panel2: #2f2f33;
    --border: rgba(255,255,255,0.09);
    --text: #f5f5f7;
    --muted: #98989d;
    --accent: #0a84ff;
    --green: #30d158;
    --red: #ff453a;
    --orange: #ff9f0a;
  }
  * { box-sizing: border-box; }
  html, body {
    margin: 0; padding: 0; height: 100%;
    background: var(--bg); color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    font-size: 13px; -webkit-font-smoothing: antialiased;
    overflow: hidden;
  }
  .app { display: flex; flex-direction: column; height: 100vh; }
  .bar {
    display: flex; align-items: center; gap: 10px;
    padding: 12px 16px; border-bottom: 1px solid var(--border);
    background: rgba(255,255,255,0.02);
  }
  .btn {
    border: none; border-radius: 10px; padding: 8px 16px;
    font-size: 13px; font-weight: 600; cursor: pointer;
    display: inline-flex; align-items: center; gap: 7px;
    color: #fff; background: var(--green); transition: opacity .15s, transform .1s;
  }
  .btn:active { transform: scale(0.98); }
  .btn.hangup { background: var(--red); }
  .btn.secondary {
    background: var(--panel2); color: var(--text);
    border: 1px solid var(--border); padding: 7px 12px; font-weight: 500;
  }
  .btn:disabled { opacity: 0.45; cursor: default; }
  .status-col { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .status-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--muted); }
  .dot.listening { background: var(--green); box-shadow: 0 0 8px rgba(48,209,88,.6); }
  .dot.thinking { background: var(--orange); box-shadow: 0 0 8px rgba(255,159,10,.6); }
  .dot.speaking { background: var(--accent); box-shadow: 0 0 8px rgba(10,132,255,.7); }
  .dot.error { background: var(--red); }
  .pill {
    font-size: 11px; padding: 2px 8px; border-radius: 999px;
    background: rgba(10,132,255,0.16); color: #64b5ff; font-weight: 500;
  }
  .pill.webrtc { background: rgba(48,209,88,0.15); color: #5ce07f; }
  .sub { font-size: 11px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .spacer { flex: 1; }
  .meter {
    width: 64px; height: 6px; border-radius: 999px; background: rgba(255,255,255,0.1); overflow: hidden;
  }
  .meter > div {
    height: 100%; width: 0%; background: var(--green); transition: width 60ms linear;
  }
  .feed {
    flex: 1; overflow-y: auto; padding: 16px;
    display: flex; flex-direction: column; gap: 10px;
  }
  .empty {
    margin: auto; max-width: 460px; text-align: left; color: var(--muted);
    background: var(--panel); border: 1px solid var(--border); border-radius: 14px; padding: 18px 20px;
  }
  .empty h3 { margin: 0 0 10px; color: var(--text); font-size: 15px; }
  .empty ol { margin: 0; padding-left: 18px; line-height: 1.55; }
  .msg { display: flex; flex-direction: column; max-width: 78%; }
  .msg.user { align-self: flex-end; align-items: flex-end; }
  .msg.assistant { align-self: flex-start; align-items: flex-start; }
  .msg .who { font-size: 11px; color: var(--muted); margin-bottom: 3px; font-weight: 600; }
  .msg.assistant .who { color: #64b5ff; }
  .msg .bubble {
    padding: 9px 13px; border-radius: 13px; line-height: 1.45;
    background: var(--panel); border: 1px solid var(--border); white-space: pre-wrap;
  }
  .msg.user .bubble { background: rgba(10,132,255,0.22); border-color: rgba(10,132,255,0.3); }
  .err-banner {
    display: none; padding: 8px 14px; background: rgba(255,69,58,0.16);
    border-bottom: 1px solid rgba(255,69,58,0.35); color: #ff8a80; font-size: 12px;
  }
  .composer {
    display: flex; gap: 8px; padding: 10px 14px;
    border-top: 1px solid var(--border); background: var(--panel);
  }
  .composer input {
    flex: 1; border: 1px solid var(--border); border-radius: 8px;
    background: var(--bg); color: var(--text); padding: 8px 11px; font-size: 13px; outline: none;
  }
  .composer input:focus { border-color: var(--accent); }
</style>
</head>
<body>
<div class="app">
  <div class="bar">
    <button id="callBtn" class="btn">Anruf starten</button>
    <div class="status-col">
      <div class="status-row">
        <span id="dot" class="dot"></span>
        <strong id="stateLabel">Bereit</strong>
        <span class="pill webrtc">WebRTC AEC</span>
        <span id="profilePill" class="pill">LiveKit</span>
      </div>
      <div id="subLabel" class="sub">Klicke auf „Anruf starten“ – echtes WebRTC-Audio mit LiveKit Silero VAD &amp; Barge-In.</div>
    </div>
    <div class="spacer"></div>
    <div id="controls" style="display:none;align-items:center;gap:8px;">
      <div class="meter"><div id="meterBar"></div></div>
      <button id="muteBtn" class="btn secondary">Stumm</button>
      <button id="firstBtn" class="btn secondary">KI beginnt</button>
    </div>
  </div>
  <div id="errBanner" class="err-banner"></div>
  <div id="feed" class="feed">
    <div id="emptyState" class="empty">
      <h3>LiveKit Echtzeit-Telefon-Agent</h3>
      <ol>
        <li>Rechts Profil wählen (<strong>100 % Lokal</strong> auf bigki, <strong>Hybrid</strong> mit ElevenLabs-Stimme oder <strong>Cloud</strong> mit ElevenLabs / OpenAI Realtime).</li>
        <li>Oben auf <strong>Anruf starten</strong> klicken – WebRTC-Echo-Cancelling, Silero VAD und Barge-In laufen automatisch.</li>
        <li>Einfach normal lossprechen oder der KI jederzeit ins Wort fallen.</li>
      </ol>
    </div>
  </div>
  <div class="composer">
    <input id="textIn" type="text" placeholder="Oder Einwand eintippen (z. B. „Keine Zeit, schicken Sie eine Mail“) …" />
    <button id="sendBtn" class="btn secondary">Senden</button>
  </div>
</div>

<audio id="remoteAudio" autoplay playsinline></audio>
<script src="/livekit-client.umd.min.js"></script>
<script>
(() => {
  const callBtn = document.getElementById('callBtn');
  const muteBtn = document.getElementById('muteBtn');
  const firstBtn = document.getElementById('firstBtn');
  const controls = document.getElementById('controls');
  const dot = document.getElementById('dot');
  const stateLabel = document.getElementById('stateLabel');
  const subLabel = document.getElementById('subLabel');
  const profilePill = document.getElementById('profilePill');
  const errBanner = document.getElementById('errBanner');
  const feed = document.getElementById('feed');
  const emptyState = document.getElementById('emptyState');
  const textIn = document.getElementById('textIn');
  const sendBtn = document.getElementById('sendBtn');
  const remoteAudio = document.getElementById('remoteAudio');
  const meterBar = document.getElementById('meterBar');

  let room = null;
  let muted = false;
  let callerName = 'Laura';
  let targetCompany = 'Hotel Alpenblick';
  let meterTimer = null;

  const profileNames = {
    local: '100 % Lokal (bigki)',
    hybrid: 'Hybrid (bigki + ElevenLabs)',
    cloud_pipeline: 'Cloud (ElevenLabs + OpenAI)',
    cloud_realtime: 'Cloud (OpenAI Realtime)'
  };

  function showError(msg) {
    if (!msg) { errBanner.style.display = 'none'; errBanner.textContent = ''; return; }
    errBanner.textContent = msg;
    errBanner.style.display = 'block';
  }

  function setState(st, sub) {
    dot.className = 'dot ' + (st === 'listening' ? 'listening' : st === 'thinking' ? 'thinking' : st === 'speaking' ? 'speaking' : st === 'error' ? 'error' : '');
    const map = { idle: 'Bereit', connecting: 'Verbinde …', listening: 'Hört zu', thinking: 'Denkt …', speaking: 'Spricht', error: 'Fehler' };
    stateLabel.textContent = map[st] || st;
    if (sub !== undefined) subLabel.textContent = sub;
  }

  function appendMsg(role, text) {
    if (emptyState) emptyState.style.display = 'none';
    const wrap = document.createElement('div');
    wrap.className = 'msg ' + role;
    const who = document.createElement('div');
    who.className = 'who';
    who.textContent = role === 'assistant' ? (callerName + ' (KI)') : (targetCompany + ' (Du)');
    const b = document.createElement('div');
    b.className = 'bubble';
    b.textContent = text;
    wrap.appendChild(who);
    wrap.appendChild(b);
    feed.appendChild(wrap);
    feed.scrollTop = feed.scrollHeight;
  }

  async function refreshConfigBadge() {
    try {
      const r = await fetch('/api/config');
      const cfg = await r.json();
      if (cfg.profile) profilePill.textContent = profileNames[cfg.profile] || cfg.profile;
      if (cfg.caller_name) callerName = cfg.caller_name;
      if (cfg.target_company) targetCompany = cfg.target_company;
    } catch {}
  }
  refreshConfigBadge();
  setInterval(refreshConfigBadge, 2000);

  async function startCall() {
    showError('');
    callBtn.disabled = true;
    setState('connecting', 'Öffne WebRTC-Leitung zu LiveKit …');
    try {
      const resp = await fetch('/api/token', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: '{}' });
      const data = await resp.json();
      if (!resp.ok) throw new Error(data.error || 'Token-Fehler');
      if (data.config) {
        callerName = data.config.caller_name || callerName;
        targetCompany = data.config.target_company || targetCompany;
        profilePill.textContent = profileNames[data.config.profile] || data.config.profile || 'LiveKit';
      }

      const LK = window.LivekitClient;
      room = new LK.Room({
        adaptiveStream: true,
        dynacast: true,
        audioCaptureDefaults: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
      });

      room.on(LK.RoomEvent.TrackSubscribed, (track) => {
        if (track.kind === LK.Track.Kind.Audio) {
          track.attach(remoteAudio);
        }
      });

      room.on(LK.RoomEvent.DataReceived, (payload) => {
        try {
          const ev = JSON.parse(new TextDecoder().decode(payload));
          if (ev.type === 'ready') {
            callerName = ev.caller_name || callerName;
            targetCompany = ev.target_company || targetCompany;
            profilePill.textContent = profileNames[ev.profile] || ev.profile;
            setState('listening', 'Leitung steht – geh ran (z. B. „' + targetCompany + ', guten Tag!“)');
          } else if (ev.type === 'state') {
            const s = ev.state || 'listening';
            const subMap = { listening: 'Hört zu …', thinking: 'Antwort wird erzeugt …', speaking: 'Spricht … (jederzeit unterbrechbar)' };
            setState(s, subMap[s] || '');
          } else if (ev.type === 'transcript') {
            appendMsg(ev.role, ev.text);
          } else if (ev.type === 'error') {
            showError(ev.message || 'Agent meldet einen Fehler.');
            setState('error', ev.message || 'Fehler');
          }
        } catch {}
      });

      room.on(LK.RoomEvent.Disconnected, () => {
        cleanupUI();
      });

      await room.connect(data.url, data.token);
      await room.localParticipant.setMicrophoneEnabled(true);

      // Clear old feed for fresh call
      feed.innerHTML = '';
      callBtn.textContent = 'Auflegen';
      callBtn.classList.add('hangup');
      callBtn.disabled = false;
      controls.style.display = 'flex';
      muted = false;
      muteBtn.textContent = 'Stumm';
      setState('listening', 'Agent tritt bei …');

      meterTimer = setInterval(() => {
        if (!room || muted) { meterBar.style.width = '0%'; return; }
        const lvl = Math.min(1, (room.localParticipant.audioLevel || 0) * 1.8);
        meterBar.style.width = Math.round(lvl * 100) + '%';
      }, 80);
    } catch (err) {
      showError(err.message || String(err));
      setState('error', 'Verbindung fehlgeschlagen.');
      cleanupUI();
    }
  }

  function cleanupUI() {
    if (meterTimer) { clearInterval(meterTimer); meterTimer = null; }
    meterBar.style.width = '0%';
    room = null;
    callBtn.textContent = 'Anruf starten';
    callBtn.classList.remove('hangup');
    callBtn.disabled = false;
    controls.style.display = 'none';
    if (stateLabel.textContent !== 'Fehler') {
      setState('idle', 'Bereit für den nächsten Anruf.');
    }
  }

  async function hangup() {
    if (room) {
      const r = room;
      room = null;
      try { await r.disconnect(); } catch {}
    }
    cleanupUI();
  }

  callBtn.addEventListener('click', () => { room ? hangup() : startCall(); });

  muteBtn.addEventListener('click', async () => {
    if (!room) return;
    muted = !muted;
    await room.localParticipant.setMicrophoneEnabled(!muted);
    muteBtn.textContent = muted ? 'Stumm (An)' : 'Stumm';
  });

  firstBtn.addEventListener('click', async () => {
    if (!room) return;
    const data = new TextEncoder().encode(JSON.stringify({ type: 'ai_speak_first' }));
    await room.localParticipant.publishData(data, { reliable: true });
  });

  async function sendTyped() {
    const txt = textIn.value.trim();
    if (!txt) return;
    if (!room) { await startCall(); await new Promise(r => setTimeout(r, 900)); }
    if (!room) return;
    textIn.value = '';
    const data = new TextEncoder().encode(JSON.stringify({ type: 'user_text', text: txt }));
    await room.localParticipant.publishData(data, { reliable: true });
  }
  sendBtn.addEventListener('click', sendTyped);
  textIn.addEventListener('keydown', (e) => { if (e.key === 'Enter') sendTyped(); });
})();
</script>
</body>
</html>
"""


def _read_config() -> dict:
    try:
        return json.loads(CONFIG_PATH.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}


def _livekit_server_ok() -> bool:
    try:
        with urllib.request.urlopen(LK_HTTP_URL, timeout=1.5) as r:
            return r.status < 500
    except OSError:
        return False


async def handle_index(_request: web.Request) -> web.Response:
    return web.Response(text=HTML_PAGE, content_type='text/html')


async def handle_client_js(_request: web.Request) -> web.StreamResponse:
    js_path = WEB_DIR / 'livekit-client.umd.min.js'
    if not js_path.is_file():
        return web.Response(status=404, text='livekit-client.umd.min.js fehlt')
    return web.FileResponse(js_path, headers={'Content-Type': 'application/javascript'})


async def handle_get_config(_request: web.Request) -> web.Response:
    return web.json_response(_read_config())


async def handle_post_config(request: web.Request) -> web.Response:
    body = await request.json()
    SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(body, ensure_ascii=False, indent=2), encoding='utf-8')
    return web.json_response({'ok': True})


async def handle_status(_request: web.Request) -> web.Response:
    return web.json_response({
        'ok': True,
        'livekit_server': _livekit_server_ok(),
        'livekit_url': LK_URL,
    })


async def handle_token(request: web.Request) -> web.Response:
    if not _livekit_server_ok():
        return web.json_response({'error': 'LiveKit-Server läuft nicht auf 127.0.0.1:7880.'}, status=503)
    cfg = _read_config()
    room_name = f'anruf-{int(time.time())}'
    # Create room with current config metadata so the agent picks up exact briefing & profile
    lk = api.LiveKitAPI(url=LK_HTTP_URL, api_key=LK_KEY, api_secret=LK_SECRET)
    try:
        await lk.room.create_room(api.CreateRoomRequest(
            name=room_name,
            metadata=json.dumps(cfg, ensure_ascii=False),
            empty_timeout=300,
        ))
    finally:
        await lk.aclose()

    token = (
        api.AccessToken(LK_KEY, LK_SECRET)
        .with_identity(f'user-{int(time.time())}')
        .with_name('Du')
        .with_grants(api.VideoGrants(room_join=True, room=room_name, can_publish=True, can_subscribe=True, can_publish_data=True))
        .to_jwt()
    )
    return web.json_response({'url': LK_URL, 'token': token, 'room': room_name, 'config': cfg})


def main() -> None:
    app = web.Application()
    app.router.add_get('/', handle_index)
    app.router.add_get('/livekit-client.umd.min.js', handle_client_js)
    app.router.add_get('/api/config', handle_get_config)
    app.router.add_post('/api/config', handle_post_config)
    app.router.add_get('/api/status', handle_status)
    app.router.add_post('/api/token', handle_token)
    web.run_app(app, host='127.0.0.1', port=BRIDGE_PORT, print=lambda *a: None)


if __name__ == '__main__':
    main()
