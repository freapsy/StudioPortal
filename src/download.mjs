import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { acquire } from './providers.mjs';
import { writeMeta } from './meta.mjs';

const resources = path.dirname(fileURLToPath(import.meta.url));
const [input, outputDir, blender] = process.argv.slice(2);
let workdir = null;
let runningChild = null;
let cancelled = false;
const aborter = new AbortController();

function event(type, data = {}) {
  process.stdout.write(JSON.stringify({ type, ...data }) + '\n');
}
function status(message) { event('status', { message }); }

function run(command, args, onLine, extraEnv = {}) {
  return new Promise((resolve, reject) => {
    if (cancelled) return reject(new Error('Abgebrochen.'));
    let tail = '';
    let settled = false;
    let buffers = { stdout: '', stderr: '' };
    const child = spawn(command, args, {
      cwd: workdir,
      env: {
        PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
        HOME: workdir,
        TMPDIR: workdir,
        LANG: 'en_US.UTF-8',
        BLENDER_USER_CONFIG: path.join(workdir, 'blender-config'),
        BLENDER_USER_SCRIPTS: path.join(workdir, 'blender-scripts'),
        ...extraEnv,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    runningChild = child;
    const consume = (which, data) => {
      const chunk = data.toString('utf8');
      tail = (tail + chunk).slice(-6000);
      buffers[which] += chunk;
      const lines = buffers[which].split(/\r?\n/);
      buffers[which] = lines.pop();
      for (const line of lines) onLine?.(line);
    };
    child.stdout.on('data', data => consume('stdout', data));
    child.stderr.on('data', data => consume('stderr', data));
    child.once('error', error => {
      if (!settled) { settled = true; runningChild = null; reject(error); }
    });
    child.once('close', code => {
      runningChild = null;
      if (settled) return;
      settled = true;
      for (const line of Object.values(buffers)) if (line) onLine?.(line);
      if (cancelled) return reject(new Error('Abgebrochen.'));
      if (code !== 0) {
        const short = tail.replace(/\x1b\[[0-9;]*m/g, '').trim().split('\n').slice(-5).join(' ').slice(-500);
        return reject(new Error(short || `Das Programm wurde mit Fehler ${code} beendet.`));
      }
      resolve();
    });
  });
}

function fixLightMatrices(file) {
  const data = fs.readFileSync(file);
  if (data.length < 28 || data.readUInt32LE(0) !== 0x46546c67 || data.readUInt32LE(4) !== 2 || data.readUInt32LE(8) !== data.length) {
    throw new Error('Die 3D-Vorschau ist unvollständig.');
  }
  const jsonLength = data.readUInt32LE(12);
  if (data.readUInt32LE(16) !== 0x4e4f534a || 20 + jsonLength > data.length) throw new Error('Ungültige 3D-Vorschaudatei.');
  const doc = JSON.parse(data.subarray(20, 20 + jsonLength).toString('utf8'));
  let fixed = 0;
  for (const node of doc.nodes || []) {
    const m = node.matrix;
    if (!node.extensions?.KHR_lights_punctual || !Array.isArray(m) || m.length !== 16) continue;
    const nearZero = n => Math.abs(n) < 1e-10;
    if (nearZero(m[12]) && nearZero(m[13]) && nearZero(m[14]) && Math.abs(m[15] - 1) < 1e-10 &&
        (!nearZero(m[3]) || !nearZero(m[7]) || !nearZero(m[11]))) {
      node.matrix = Array.from({ length: 16 }, (_, i) => m[(i % 4) * 4 + Math.floor(i / 4)]);
      fixed++;
    }
  }
  if (!fixed) return file;
  let json = Buffer.from(JSON.stringify(doc), 'utf8');
  const pad = (4 - json.length % 4) % 4;
  if (pad) json = Buffer.concat([json, Buffer.alloc(pad, 0x20)]);
  const rest = data.subarray(20 + jsonLength);
  const header = Buffer.alloc(20);
  header.writeUInt32LE(0x46546c67, 0); header.writeUInt32LE(2, 4);
  header.writeUInt32LE(20 + json.length + rest.length, 8);
  header.writeUInt32LE(json.length, 12); header.writeUInt32LE(0x4e4f534a, 16);
  const fixedPath = path.join(workdir, 'model-fixed.glb');
  fs.writeFileSync(fixedPath, Buffer.concat([header, json, rest]));
  return fixedPath;
}

function outputName(name) {
  const cleaned = String(name).normalize('NFKD').replace(/[\u0300-\u036f]/g, '').replace(/\.(glb|gltf|blend|stl|obj|fbx|3mf|zip|ply)$/i, '').replace(/[^a-zA-Z0-9._-]+/g, '_').replace(/^\.+|\.+$/g, '').slice(0, 120);
  return cleaned || '3D_Modell';
}

function copyUnique(source, directory, base) {
  fs.mkdirSync(directory, { recursive: true });
  for (let i = 1; i <= 1000; i++) {
    const file = path.join(directory, base + (i === 1 ? '' : `_${i}`) + '.blend');
    try {
      fs.copyFileSync(source, file, fs.constants.COPYFILE_EXCL);
      if (fs.statSync(file).size !== fs.statSync(source).size) throw new Error('Die gespeicherte Datei ist unvollständig.');
      return file;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
  }
  throw new Error('Kein freier Dateiname gefunden.');
}

function cancel() {
  cancelled = true;
  aborter.abort();
  if (runningChild) {
    const child = runningChild;
    child.kill('SIGTERM');
    const timer = setTimeout(() => { if (runningChild === child) child.kill('SIGKILL'); }, 3000);
    timer.unref();
  }
}
process.on('SIGTERM', cancel);
process.on('SIGINT', cancel);

try {
  if (!outputDir || !blender || !fs.existsSync(blender)) throw new Error('Blender wurde nicht gefunden.');
  workdir = fs.mkdtempSync(path.join(os.tmpdir(), 'modell-zu-blender-'));
  status(String(input).startsWith('file://') ? '3D-Datei wird vorbereitet …' : '3D-Modell wird heruntergeladen …');
  const asset = await acquire(input, {
    workdir, signal: aborter.signal, status,
    sketchfab: async uid => {
      const out = path.join(workdir, 'viewer');
      await run(process.execPath, [path.join(resources, 'sfrip', 'sfrip.mjs'), uid, '--out', out, '--yes', '--no-color', '--verbose'], line => {
        if (line.includes('decrypting model_file.binz')) status('3D-Geometrie wird verarbeitet …');
        else if (line.includes('texture(s) ready')) status('Materialien werden vorbereitet …');
      });
      const folders = fs.readdirSync(out, { withFileTypes: true }).filter(e => e.isDirectory());
      if (folders.length !== 1) throw new Error('Das heruntergeladene Modell konnte nicht gefunden werden.');
      const folder = path.join(out, folders[0].name);
      const glbs = fs.readdirSync(folder).filter(n => n.toLowerCase().endsWith('.glb'));
      if (glbs.length !== 1) throw new Error('Die 3D-Vorschau konnte nicht erstellt werden.');
      return { source: fixLightMatrices(path.join(folder, glbs[0])), name: glbs[0] };
    }
  });
  if (cancelled) throw new Error('Abgebrochen.');
  const outputTemp = path.join(workdir, 'Modell.blend');
  status('Blender-Datei wird erstellt …');
  await run(blender, ['--background', '--factory-startup', '--disable-autoexec', '--python-exit-code', '1', '--python', path.join(resources, 'convert.py'), '--', asset.source, outputTemp], line => {
    if (line.startsWith('HINWEIS_3MF:')) event('notice', { message: line.slice('HINWEIS_3MF:'.length).trim() });
  }, { STUDIOPORTAL_THUMBNAIL: path.join(workdir, 'preview.png') });
  if (cancelled) throw new Error('Abgebrochen.');
  if (!fs.existsSync(outputTemp) || fs.statSync(outputTemp).size < 1000) throw new Error('Die Blender-Datei wurde nicht erstellt.');
  const result = copyUnique(outputTemp, outputDir, outputName(asset.name));
  writeMeta(result, { kind: 'model', source: 'import', link: String(input).startsWith('file://') ? decodeURIComponent(new URL(input).pathname) : String(input) },
    path.join(workdir, 'preview.png'));
  event('done', { path: result });
} catch (error) {
  event(cancelled ? 'cancelled' : 'error', { message: cancelled ? 'Abgebrochen.' : String(error?.message || error) });
  process.exitCode = cancelled ? 130 : 1;
} finally {
  if (workdir) {
    try { fs.rmSync(workdir, { recursive: true, force: true }); } catch { /* temporary files can be cleaned by macOS */ }
  }
}
