#!/usr/bin/env python3
"""StudioPortal LiveKit Voice Agent — unified real-time phone agent supporting 4 switchable profiles:
  - local:          100% local on bigki (Nemotron 3.5 ASR + Qwen 3.8 Flash Strata + Drama 3 / Qwen3-TTS)
  - hybrid:         bigki Qwen 3.8 Flash LLM (0 €/Token) + ElevenLabs v4 Turbo voice (+ bigki or Cloud STT)
  - cloud_pipeline: OpenAI / Deepgram STT + OpenAI LLM + ElevenLabs v4 Turbo voice
  - cloud_realtime: OpenAI Realtime API (native Audio-to-Audio Speech-to-Speech)

Runs locally against livekit-server (ws://127.0.0.1:7880) or any LiveKit Cloud / SIP deployment.
API keys are loaded strictly from ~/Library/Application Support/StudioPortal/livekit-keys.json.
"""
from __future__ import annotations

import asyncio
import base64
import io
import json
import logging
import os
import time
import uuid
import wave
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
from livekit import rtc
from livekit.agents import (
    Agent,
    AgentServer,
    AgentSession,
    APIConnectOptions,
    JobContext,
    JobProcess,
    cli,
    llm,
    stt,
    tts,
    utils,
)
from livekit.agents.types import DEFAULT_API_CONNECT_OPTIONS, NOT_GIVEN, NotGivenOr
from livekit.plugins import deepgram, elevenlabs, openai, silero

logging.basicConfig(level=logging.INFO, format='[livekit-agent] %(levelname)s %(message)s')
log = logging.getLogger('studioportal.livekit')

SUPPORT_DIR = Path.home() / 'Library' / 'Application Support' / 'StudioPortal'
CONFIG_PATH = SUPPORT_DIR / 'livekit-call-config.json'
KEYS_PATH = SUPPORT_DIR / 'livekit-keys.json'
CALLS_DIR = Path.home() / 'Music' / 'StudioPortal-Sprache' / 'Anrufe'

REMOTE_HOST = 'bigki@GPU-SERVER-IP'
PORTAL_KEY = Path.home() / '.ssh' / '3d-modelle-bigki'
PORTAL_KNOWN_HOSTS = Path.home() / '.ssh' / '3d-modelle-bigki-known_hosts'

DEFAULT_ELEVENLABS_VOICE = 'Yeon'
DEFAULT_ELEVENLABS_MODEL = 'eleven_v4_turbo'
KNOWN_ELEVENLABS_VOICES: dict[str, str] = {
    'yeon': 'WNpDisiMIzLl7ft2rYeN',
    'yeon - deep and emotional': 'WNpDisiMIzLl7ft2rYeN',
}
_VOICE_ID_CACHE: dict[str, str] = {}


def resolve_elevenlabs_voice_id(voice_spec: str, api_key: str) -> str:
    """Accepts either a raw ElevenLabs voice_id or a display name like 'Yeon' and resolves it via API."""
    spec = (voice_spec or '').strip() or DEFAULT_ELEVENLABS_VOICE
    if spec in _VOICE_ID_CACHE:
        return _VOICE_ID_CACHE[spec]
    # Fast path for built-in verified aliases (zero network round-trip)
    if spec.lower() in KNOWN_ELEVENLABS_VOICES:
        vid = KNOWN_ELEVENLABS_VOICES[spec.lower()]
        _VOICE_ID_CACHE[spec] = vid
        return vid
    # Raw ElevenLabs IDs are 20+ char alphanumeric strings without spaces
    if len(spec) >= 18 and spec.isalnum() and any(c.isdigit() for c in spec):
        return spec
    import urllib.parse
    import urllib.request
    headers = {'xi-api-key': api_key}
    low = spec.lower()
    # 1) Check account voices first
    try:
        req = urllib.request.Request('https://api.elevenlabs.io/v1/voices', headers=headers)
        with urllib.request.urlopen(req, timeout=10) as r:
            voices = json.loads(r.read().decode()).get('voices', [])
        for exact in (True, False):
            for v in voices:
                name = str(v.get('name') or '').strip()
                if (name.lower() == low) if exact else (low in name.lower()):
                    vid = str(v['voice_id'])
                    _VOICE_ID_CACHE[spec] = vid
                    log.info('Resolved ElevenLabs voice %r -> %s (%s)', spec, vid, name)
                    return vid
    except Exception as exc:
        log.warning('Failed to query /v1/voices for %r: %s', spec, exc)
    # 2) Fallback: search shared Voice Library
    try:
        url = 'https://api.elevenlabs.io/v1/shared-voices?search=' + urllib.parse.quote(spec) + '&page_size=10'
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as r:
            voices = json.loads(r.read().decode()).get('voices', [])
        if voices:
            vid = str(voices[0]['voice_id'])
            _VOICE_ID_CACHE[spec] = vid
            log.info('Resolved ElevenLabs shared voice %r -> %s (%s)', spec, vid, voices[0].get('name'))
            return vid
    except Exception as exc:
        log.warning('Failed to query /v1/shared-voices for %r: %s', spec, exc)
    return spec
DEFAULT_SYSTEM_PROMPT = (
    'Du bist Laura von Studio Nordweb in einem echten deutschen Telefonat auf Augenhöhe mit „Hotel Alpenblick“.\n'
    'Anlass: Auf dem Smartphone ist der Buchen-Knopf im Buchungsformular halb abgeschnitten und die Seite lädt über 6 Sekunden.\n'
    'Ziel: Locker und ohne Druck anbieten, kurz einen kostenlosen 2-Minuten-Video-Check vom Fehler an deren E-Mail zu schicken.\n'
    'Anrede: Sieze konsequent. Verwende KEIN „Herr“ oder „Frau“ beim Namen – begrüße immer direkt mit „Grüß Sie“ oder „Guten Tag“!\n'
    'Regeln: Maximal 1–2 kurze, natürliche gesprochene Sätze ohne Markdown oder Klammern. Niemals „Haben Sie einen Moment Zeit?“.'
)


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}


def load_call_config(room_metadata: str | None = None) -> dict[str, Any]:
    cfg = load_json(CONFIG_PATH)
    if room_metadata:
        try:
            meta = json.loads(room_metadata)
            if isinstance(meta, dict):
                cfg.update(meta)
        except ValueError:
            pass
    return cfg


def load_keys() -> dict[str, str]:
    raw = load_json(KEYS_PATH)
    return {k: str(v).strip() for k, v in raw.items() if isinstance(v, str) and v.strip()}


# --------------------------------------------------------------------------- persistent SSH bridge to bigki
class BigkiSessionBridge:
    """Keeps ONE persistent SSH `phone/session` open to bigki_worker.py via the restricted portalKey."""

    def __init__(self) -> None:
        self._proc: asyncio.subprocess.Process | None = None
        self._reader_task: asyncio.Task | None = None
        self._write_lock = asyncio.Lock()
        self._open_lock = asyncio.Lock()
        self._next_id = 1
        self._queues: dict[int, asyncio.Queue[dict[str, Any]]] = {}
        self._ready_event = asyncio.Event()

    async def ensure_open(self) -> None:
        async with self._open_lock:
            if self._proc is not None and self._proc.returncode is None:
                return
            if not (PORTAL_KEY.is_file() and PORTAL_KNOWN_HOSTS.is_file()):
                raise RuntimeError('StudioPortal SSH-Schlüssel für bigki fehlt (~/.ssh/3d-modelle-bigki).')
            self._ready_event.clear()
            args = [
                '/usr/bin/ssh', '-T', '-i', str(PORTAL_KEY),
                '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
                '-o', 'StrictHostKeyChecking=yes',
                '-o', f'UserKnownHostsFile={PORTAL_KNOWN_HOSTS}',
                '-o', 'GlobalKnownHostsFile=/dev/null',
                '-o', 'ConnectTimeout=12',
                '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=12',
                '-o', 'ClearAllForwardings=yes',
                REMOTE_HOST, 'studioportal',
            ]
            self._proc = await asyncio.create_subprocess_exec(
                *args,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
                limit=16 * 1024 * 1024,
            )
            self._reader_task = asyncio.create_task(self._read_loop())
            init_line = json.dumps({'operation': 'phone', 'action': 'session', 'origin': 'LiveKit Agent'}) + '\n'
            assert self._proc.stdin is not None
            self._proc.stdin.write(init_line.encode('utf-8'))
            await self._proc.stdin.drain()
            await asyncio.wait_for(self._ready_event.wait(), timeout=12.0)
            log.info('Persistent bigki phone/session bridge ready.')

    async def _read_loop(self) -> None:
        assert self._proc is not None and self._proc.stdout is not None
        try:
            while True:
                raw = await self._proc.stdout.readline()
                if not raw:
                    break
                try:
                    ev = json.loads(raw.decode('utf-8', 'replace'))
                except ValueError:
                    continue
                kind = ev.get('type')
                if kind == 'session_ready':
                    self._ready_event.set()
                    continue
                req_id = ev.get('id')
                if isinstance(req_id, int) and req_id in self._queues:
                    await self._queues[req_id].put(ev)
        except asyncio.CancelledError:
            pass
        finally:
            for q in list(self._queues.values()):
                await q.put({'type': 'session_error', 'message': 'bigki-Verbindung getrennt.'})
            self._queues.clear()

    async def _send(self, payload: dict[str, Any]) -> None:
        assert self._proc is not None and self._proc.stdin is not None
        line = (json.dumps(payload, ensure_ascii=False) + '\n').encode('utf-8')
        async with self._write_lock:
            self._proc.stdin.write(line)
            await self._proc.stdin.drain()

    async def request_stream(self, cmd: str, payload: dict[str, Any]):
        await self.ensure_open()
        req_id = self._next_id
        self._next_id += 1
        q: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self._queues[req_id] = q
        try:
            await self._send({'id': req_id, 'cmd': cmd, **payload})
            while True:
                ev = await q.get()
                yield ev
                if ev.get('type') in ('session_result', 'session_error', 'session_cancelled'):
                    break
        except asyncio.CancelledError:
            try:
                await self._send({'cmd': 'cancel', 'id': req_id})
            except Exception:
                pass
            raise
        finally:
            self._queues.pop(req_id, None)

    async def close(self) -> None:
        if self._proc is not None and self._proc.returncode is None:
            try:
                await self._send({'cmd': 'quit'})
            except Exception:
                pass
            try:
                self._proc.terminate()
            except Exception:
                pass
        if self._reader_task is not None:
            self._reader_task.cancel()
        self._proc = None


# --------------------------------------------------------------------------- Custom LiveKit Plugins for bigki
def audio_buffer_to_16k_wav_b64(buffer: utils.AudioBuffer) -> str:
    combined = utils.audio.combine_frames(buffer)
    sr = combined.sample_rate
    ch = combined.num_channels
    samples = np.frombuffer(combined.data, dtype=np.int16)
    if ch > 1:
        samples = samples.reshape(-1, ch)[:, 0]
    if sr != 16000 and len(samples) > 1:
        f = samples.astype(np.float32)
        idx = np.linspace(0, len(f) - 1, max(1, int(len(f) * 16000 / sr)))
        samples = np.interp(idx, np.arange(len(f)), f).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(16000)
        out.writeframes(samples.tobytes())
    return base64.b64encode(buf.getvalue()).decode('ascii')


class BigkiNemotronSTT(stt.STT):
    """LiveKit STT plugin backed by Nemotron 3.5 ASR (0.6B Q8, de-DE) on bigki's AVX-512 CPU."""

    def __init__(self, bridge: BigkiSessionBridge, language: str = 'de-DE') -> None:
        super().__init__(capabilities=stt.STTCapabilities(streaming=False, interim_results=False))
        self._bridge = bridge
        self._language = language

    async def _recognize_impl(
        self,
        buffer: utils.AudioBuffer,
        *,
        language: NotGivenOr[str] = NOT_GIVEN,
        conn_options: APIConnectOptions = DEFAULT_API_CONNECT_OPTIONS,
    ) -> stt.SpeechEvent:
        wav_b64 = audio_buffer_to_16k_wav_b64(buffer)
        lang = language if isinstance(language, str) and language else self._language
        text = ''
        async for ev in self._bridge.request_stream('listen', {
            'audio_b64': wav_b64,
            'check_turn': False,
            'transcribe': True,
            'force_transcribe': True,
            'language': lang,
        }):
            if ev.get('type') == 'session_result':
                text = (ev.get('result') or {}).get('text', '').strip()
            elif ev.get('type') == 'session_error':
                raise RuntimeError(ev.get('message') or 'Nemotron STT Fehler')
        return stt.SpeechEvent(
            type=stt.SpeechEventType.FINAL_TRANSCRIPT,
            alternatives=[stt.SpeechData(language='de', text=text)],
        )


class _BigkiLLMStream(llm.LLMStream):
    def __init__(
        self,
        llm_inst: 'BigkiStrataLLM',
        bridge: BigkiSessionBridge,
        *,
        chat_ctx: llm.ChatContext,
        tools: list[llm.Tool],
        conn_options: APIConnectOptions,
        temperature: float,
        max_tokens: int,
    ) -> None:
        super().__init__(llm_inst, chat_ctx=chat_ctx, tools=tools, conn_options=conn_options)
        self._bridge = bridge
        self._temperature = temperature
        self._max_tokens = max_tokens

    async def _run(self) -> None:
        raw_msgs, _ = self._chat_ctx.to_provider_format(format='openai')
        clean_msgs: list[dict[str, str]] = []
        for m in raw_msgs:
            role = m.get('role')
            if role not in ('system', 'user', 'assistant', 'developer'):
                continue
            if role == 'developer':
                role = 'system'
            content = m.get('content')
            if isinstance(content, list):
                content = ' '.join(
                    part.get('text', '') for part in content if isinstance(part, dict) and part.get('type') == 'text'
                ).strip()
            if isinstance(content, str) and content.strip():
                clean_msgs.append({'role': role, 'content': content})
        req_id = f'strata-{uuid.uuid4().hex[:8]}'
        async for ev in self._bridge.request_stream('llm_stream', {
            'messages': clean_msgs,
            'temperature': self._temperature,
            'max_tokens': self._max_tokens,
        }):
            kind = ev.get('type')
            if kind == 'token':
                piece = ev.get('text') or ''
                if piece:
                    self._event_ch.send_nowait(
                        llm.ChatChunk(id=req_id, delta=llm.ChoiceDelta(role='assistant', content=piece))
                    )
            elif kind == 'session_error':
                raise RuntimeError(ev.get('message') or 'Strata LLM Fehler')


class BigkiStrataLLM(llm.LLM):
    """LiveKit LLM plugin backed by 2-card Strata (Qwen 3.8 Flash, reasoning OFF) on bigki."""

    def __init__(self, bridge: BigkiSessionBridge, temperature: float = 0.65, max_tokens: int = 100) -> None:
        super().__init__()
        self._bridge = bridge
        self._temperature = temperature
        self._max_tokens = max_tokens

    def chat(
        self,
        *,
        chat_ctx: llm.ChatContext,
        tools: list[llm.Tool] | None = None,
        conn_options: APIConnectOptions = DEFAULT_API_CONNECT_OPTIONS,
        parallel_tool_calls: NotGivenOr[bool] = NOT_GIVEN,
        tool_choice: NotGivenOr[llm.ToolChoice] = NOT_GIVEN,
        extra_kwargs: NotGivenOr[dict[str, Any]] = NOT_GIVEN,
    ) -> llm.LLMStream:
        return _BigkiLLMStream(
            self, self._bridge,
            chat_ctx=chat_ctx, tools=tools or [], conn_options=conn_options,
            temperature=self._temperature, max_tokens=self._max_tokens,
        )


class _BigkiTTSStream(tts.ChunkedStream):
    def __init__(
        self,
        *,
        tts_inst: 'BigkiDrama3TTS',
        input_text: str,
        conn_options: APIConnectOptions,
    ) -> None:
        super().__init__(tts=tts_inst, input_text=input_text, conn_options=conn_options)
        self._tts_inst = tts_inst

    async def _run(self, output_emitter: tts.AudioEmitter) -> None:
        sr = self._tts_inst.sample_rate
        output_emitter.initialize(
            request_id=f'drama3-{uuid.uuid4().hex[:8]}',
            sample_rate=sr,
            num_channels=1,
            mime_type='audio/pcm',
        )
        text = self._input_text.strip()
        if not text:
            output_emitter.flush()
            return
        payload: dict[str, Any] = {
            'text': text,
            'tts_engine': self._tts_inst.engine,
            'voice_preset': self._tts_inst.voice_preset,
            'voice_style': self._tts_inst.voice_style,
            'tts_temperature': self._tts_inst.temperature,
            'seed': self._tts_inst.seed,
            'speaker': self._tts_inst.qwen_speaker,
            'instruct': self._tts_inst.qwen_instruct,
        }
        async for ev in self._tts_inst.bridge.request_stream('tts_stream', payload):
            kind = ev.get('type')
            if kind == 'audio_chunk':
                b64 = ev.get('pcm_b64') or ''
                if b64:
                    output_emitter.push(base64.b64decode(b64))
            elif kind == 'session_error':
                raise RuntimeError(ev.get('message') or 'Drama 3 TTS Fehler')
        output_emitter.flush()


class BigkiDrama3TTS(tts.TTS):
    """LiveKit streaming TTS plugin backed by Fish Audio Drama 3 / Qwen3-TTS on bigki GPU 1."""

    def __init__(
        self,
        bridge: BigkiSessionBridge,
        *,
        engine: str = 'drama-3',
        voice_preset: str = 'laura',
        voice_style: str = '[calm, warm]',
        temperature: float = 0.76,
        seed: int = 1337,
        qwen_speaker: str = 'Ryan',
        qwen_instruct: str = 'Freundlich, ruhig, natürlich am Telefon auf Deutsch.',
    ) -> None:
        sr = 24000 if engine == 'qwen3-tts' else 44100
        super().__init__(capabilities=tts.TTSCapabilities(streaming=False), sample_rate=sr, num_channels=1)
        self.bridge = bridge
        self.engine = engine
        self.voice_preset = voice_preset
        self.voice_style = voice_style if engine == 'drama-3' else None
        self.temperature = temperature
        self.seed = seed
        self.qwen_speaker = qwen_speaker
        self.qwen_instruct = qwen_instruct

    def synthesize(
        self,
        text: str,
        *,
        conn_options: APIConnectOptions = DEFAULT_API_CONNECT_OPTIONS,
    ) -> tts.ChunkedStream:
        return _BigkiTTSStream(tts_inst=self, input_text=text, conn_options=conn_options)


# --------------------------------------------------------------------------- LiveKit Agent Server
server = AgentServer()


def prewarm_process(proc: JobProcess) -> None:
    proc.userdata['vad'] = silero.VAD.load()


server.setup_fnc = prewarm_process


def build_session_for_profile(
    cfg: dict[str, Any],
    keys: dict[str, str],
    vad: silero.VAD,
    bridge: BigkiSessionBridge | None,
) -> AgentSession:
    profile = str(cfg.get('profile') or 'local')
    openai_key = keys.get('openai_api_key', '')
    eleven_key = keys.get('elevenlabs_api_key', '')
    deepgram_key = keys.get('deepgram_api_key', '')

    if profile == 'cloud_realtime':
        if not openai_key:
            raise RuntimeError('OpenAI API-Key fehlt (unter API-Schlüssel in der Seitenleiste eintragen).')
        rt_model = str(cfg.get('openai_realtime_model') or 'gpt-realtime')
        rt_voice = str(cfg.get('openai_voice') or 'marin')
        log.info('Starting profile=cloud_realtime (model=%s, voice=%s)', rt_model, rt_voice)
        return AgentSession(
            llm=openai.realtime.RealtimeModel(
                model=rt_model,
                voice=rt_voice,
                api_key=openai_key,
                temperature=0.7,
            ),
            allow_interruptions=True,
        )

    # Pipeline profiles: local | hybrid | cloud_pipeline
    # 1) STT
    stt_inst: stt.STT
    if profile == 'cloud_pipeline':
        if deepgram_key:
            stt_inst = deepgram.STT(model='nova-3', language='de', api_key=deepgram_key)
        elif openai_key:
            stt_inst = stt.StreamAdapter(
                stt=openai.STT(model='gpt-4o-mini-transcribe', language='de', api_key=openai_key),
                vad=vad,
            )
        else:
            raise RuntimeError('Für Cloud-Pipeline bitte OpenAI- oder Deepgram-API-Key eintragen.')
    elif profile == 'hybrid':
        if deepgram_key:
            stt_inst = deepgram.STT(model='nova-3', language='de', api_key=deepgram_key)
        elif openai_key:
            stt_inst = stt.StreamAdapter(
                stt=openai.STT(model='gpt-4o-mini-transcribe', language='de', api_key=openai_key),
                vad=vad,
            )
        else:
            assert bridge is not None
            stt_inst = stt.StreamAdapter(stt=BigkiNemotronSTT(bridge, language='de-DE'), vad=vad)
    else:  # local
        assert bridge is not None
        stt_inst = stt.StreamAdapter(stt=BigkiNemotronSTT(bridge, language='de-DE'), vad=vad)

    # 2) LLM
    llm_inst: llm.LLM
    if profile == 'cloud_pipeline':
        if not openai_key:
            raise RuntimeError('OpenAI API-Key fehlt für Cloud-Pipeline.')
        llm_inst = openai.LLM(
            model=str(cfg.get('openai_model') or 'gpt-4.1-mini'),
            api_key=openai_key,
            temperature=0.65,
        )
    else:
        assert bridge is not None
        llm_inst = BigkiStrataLLM(bridge, temperature=0.65, max_tokens=100)

    # 3) TTS
    tts_inst: tts.TTS
    if profile in ('hybrid', 'cloud_pipeline'):
        if not eleven_key:
            raise RuntimeError('ElevenLabs API-Key fehlt (unter Cloud-API-Schlüssel in der Seitenleiste eintragen).')
        el_voice_spec = str(cfg.get('elevenlabs_voice_id') or '').strip() or DEFAULT_ELEVENLABS_VOICE
        el_voice = resolve_elevenlabs_voice_id(el_voice_spec, eleven_key)
        el_model = str(cfg.get('elevenlabs_model') or DEFAULT_ELEVENLABS_MODEL).strip()
        is_dialogue = el_model.startswith(('eleven_v3', 'eleven_v4'))
        el_kwargs: dict[str, Any] = {
            'api_key': eleven_key,
            'voice_id': el_voice,
            'model': el_model,
            'language': 'de',
            'encoding': 'pcm_24000',
        }
        if not is_dialogue:
            el_kwargs['streaming_latency'] = 2
        tts_inst = elevenlabs.TTS(**el_kwargs)
    else:
        assert bridge is not None
        tts_inst = BigkiDrama3TTS(
            bridge,
            engine=str(cfg.get('tts_engine') or 'drama-3'),
            voice_preset=str(cfg.get('voice_preset') or 'laura'),
            voice_style=str(cfg.get('voice_style') or '[calm, warm]'),
            temperature=float(cfg.get('tts_temperature') or 0.76),
            seed=int(cfg.get('seed') or 1337),
            qwen_speaker=str(cfg.get('qwen_speaker') or 'Ryan'),
            qwen_instruct=str(cfg.get('qwen_instruct') or 'Freundlich, ruhig, natürlich am Telefon auf Deutsch.'),
        )

    log.info('Starting profile=%s (stt=%s, llm=%s, tts=%s)', profile, type(stt_inst).__name__, type(llm_inst).__name__, type(tts_inst).__name__)
    return AgentSession(
        vad=vad,
        stt=stt_inst,
        llm=llm_inst,
        tts=tts_inst,
        turn_detection='vad',
        allow_interruptions=True,
        resume_false_interruption=True,
        min_endpointing_delay=0.35,
        max_endpointing_delay=1.6,
        preemptive_generation=True,
    )


@server.rtc_session()
async def phone_entrypoint(ctx: JobContext) -> None:
    await ctx.connect()
    cfg = load_call_config(ctx.room.metadata)
    keys = load_keys()
    profile = str(cfg.get('profile') or 'local')
    instructions = str(cfg.get('instructions') or DEFAULT_SYSTEM_PROMPT)
    target_company = str(cfg.get('target_company') or 'Hotel Alpenblick')
    scenario_title = str(cfg.get('scenario_title') or 'Akquise-Test')
    caller_name = str(cfg.get('caller_name') or 'Laura')

    vad: silero.VAD = ctx.proc.userdata.get('vad') or silero.VAD.load()
    needs_bigki = profile in ('local', 'hybrid')
    bridge = BigkiSessionBridge() if needs_bigki else None

    transcript_log: list[dict[str, Any]] = []
    started_at = datetime.now(timezone.utc)

    async def publish_ui(event: dict[str, Any]) -> None:
        try:
            payload = json.dumps(event, ensure_ascii=False).encode('utf-8')
            await ctx.room.local_participant.publish_data(payload, reliable=True)
        except Exception:
            pass

    try:
        if bridge is not None:
            await bridge.ensure_open()
            # Pre-warm Strata KV prefix cache cleanly in background
            asyncio.create_task(_prewarm_bigki(bridge, instructions))
        session = build_session_for_profile(cfg, keys, vad, bridge)
    except Exception as exc:
        log.error('Session init failed: %s', exc)
        await publish_ui({'type': 'error', 'message': str(exc)})
        if bridge is not None:
            await bridge.close()
        return

    @session.on('agent_state_changed')
    def _on_agent_state(ev) -> None:
        asyncio.create_task(publish_ui({'type': 'state', 'state': str(ev.new_state)}))

    @session.on('user_input_transcribed')
    def _on_user_transcript(ev) -> None:
        if getattr(ev, 'is_final', True) and (ev.transcript or '').strip():
            txt = ev.transcript.strip()
            transcript_log.append({'role': 'user', 'text': txt, 'ts': time.time()})
            asyncio.create_task(publish_ui({'type': 'transcript', 'role': 'user', 'text': txt}))

    @session.on('conversation_item_added')
    def _on_item_added(ev) -> None:
        item = getattr(ev, 'item', None)
        if item is None:
            return
        role = getattr(item, 'role', None)
        text = getattr(item, 'text_content', None) or ''
        if role == 'assistant' and text.strip():
            txt = text.strip()
            transcript_log.append({'role': 'assistant', 'text': txt, 'ts': time.time()})
            asyncio.create_task(publish_ui({'type': 'transcript', 'role': 'assistant', 'text': txt}))

    @ctx.room.on('data_received')
    def _on_data(packet: rtc.DataPacket) -> None:
        try:
            msg = json.loads(packet.data.decode('utf-8'))
        except ValueError:
            return
        kind = msg.get('type')
        if kind == 'user_text':
            txt = str(msg.get('text') or '').strip()
            if txt:
                transcript_log.append({'role': 'user', 'text': txt, 'ts': time.time()})
                asyncio.create_task(publish_ui({'type': 'transcript', 'role': 'user', 'text': txt}))
                session.generate_reply(user_input=txt)
        elif kind == 'ai_speak_first':
            session.generate_reply(
                instructions='Der Gesprächspartner hat gerade abgenommen und kurz „Hallo?“ gesagt. Begrüße ihn jetzt locker und komm sofort zum Punkt.'
            )

    agent = Agent(instructions=instructions)
    await session.start(room=ctx.room, agent=agent)

    await publish_ui({
        'type': 'ready',
        'profile': profile,
        'caller_name': caller_name,
        'target_company': target_company,
    })

    if cfg.get('ai_speaks_first'):
        session.generate_reply(
            instructions='Der Gesprächspartner hat gerade abgenommen. Begrüße ihn jetzt locker und komm sofort zum Punkt.'
        )

    # Save call transcript on shutdown
    async def _on_shutdown() -> None:
        if transcript_log:
            try:
                CALLS_DIR.mkdir(parents=True, exist_ok=True)
                stamp = datetime.now().strftime('%Y-%m-%d-%H%M%S')
                out = CALLS_DIR / f'anruf-livekit-{stamp}.json'
                out.write_text(json.dumps({
                    'date': started_at.isoformat(),
                    'title': target_company,
                    'scenario': f'{scenario_title} (LiveKit · {profile})',
                    'tts_engine': f'livekit:{profile}',
                    'messages': [
                        {'role': m['role'], 'text': m['text'], 'interrupted': False}
                        for m in transcript_log
                    ],
                }, ensure_ascii=False, indent=2), encoding='utf-8')
            except OSError:
                pass
        if bridge is not None:
            await bridge.close()

    ctx.add_shutdown_callback(_on_shutdown)


async def _prewarm_bigki(bridge: BigkiSessionBridge, instructions: str) -> None:
    try:
        async for _ in bridge.request_stream('warmup', {
            'messages': [
                {'role': 'system', 'content': instructions},
                {'role': 'user', 'content': '(Leitung steht, gleich meldet sich das Gegenüber.)'},
            ],
        }):
            pass
    except Exception:
        pass


if __name__ == '__main__':
    os.environ.setdefault('LIVEKIT_URL', 'ws://127.0.0.1:7880')
    os.environ.setdefault('LIVEKIT_API_KEY', 'devkey')
    os.environ.setdefault('LIVEKIT_API_SECRET', 'secret')
    cli.run_app(server)
