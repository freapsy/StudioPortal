import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import readline from 'node:readline';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { writeMeta } from './meta.mjs';

const resources = path.dirname(fileURLToPath(import.meta.url));
const [outputDir, blender] = process.argv.slice(2);
const sshDir = path.join(os.homedir(), '.ssh');
const key = path.join(sshDir, '3d-modelle-bigki');
const knownHosts = path.join(sshDir, '3d-modelle-bigki-known_hosts');
let active = null;
let cancelled = false;
let workdir;

function event(type, fields = {}) { process.stdout.write(JSON.stringify({ type, ...fields }) + '\n'); }
function status(message) { event('status', { message }); }
function cancel() {
  cancelled = true;
  if (!active) return;
  const child = active;
  if (child.remote && child.stdin && !child.stdin.destroyed) {
    child.stdin.end();
    const timer = setTimeout(() => { if (active === child) child.kill('SIGTERM'); }, 10000);
    timer.unref();
  } else {
    child.kill('SIGTERM');
  }
}
process.on('SIGTERM', cancel);
process.on('SIGINT', cancel);

function run(command, args, extraEnv = {}) {
  return new Promise((resolve, reject) => {
    if (cancelled) return reject(new Error('Abgebrochen.'));
    let tail = '';
    const child = spawn(command, args, { cwd: workdir, stdio: ['ignore', 'pipe', 'pipe'],
      env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', HOME: workdir, TMPDIR: workdir,
        LANG: 'en_US.UTF-8', BLENDER_USER_CONFIG: path.join(workdir, 'blender-config'),
        BLENDER_USER_SCRIPTS: path.join(workdir, 'blender-scripts'), ...extraEnv } });
    active = child;
    child.stdout.on('data', data => { tail = (tail + data.toString()).slice(-4000); });
    child.stderr.on('data', data => { tail = (tail + data.toString()).slice(-4000); });
    child.once('error', reject);
    child.once('close', code => {
      if (active === child) active = null;
      if (cancelled) reject(new Error('Abgebrochen.'));
      else if (code !== 0) reject(new Error(tail.trim().slice(-600) || `Programmfehler ${code}.`));
      else resolve();
    });
  });
}

function transfer(request, target) {
  return new Promise((resolve, reject) => {
    let stderr = '';
    let remoteError = '';
    let expected = null;
    let bytes = 0;
    let complete = false;
    let fd;
    const hash = crypto.createHash('sha256');
    const child = spawn('/usr/bin/ssh', ['-T', '-i', key, '-o', 'BatchMode=yes',
      '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
      '-o', `UserKnownHostsFile=${knownHosts}`, '-o', 'GlobalKnownHostsFile=/dev/null',
      '-o', 'ConnectTimeout=12', '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3',
      '-o', 'ClearAllForwardings=yes', 'bigki@GPU-SERVER-IP', 'studioportal'],
      { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, LANG: 'en_US.UTF-8' } });
    child.remote = true;
    active = child;
    child.stderr.on('data', data => { stderr = (stderr + data.toString()).slice(-1500); });
    child.stdin.on('error', () => {});
    const lines = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
    lines.on('line', line => {
      try {
        const value = JSON.parse(line);
        if (value.type === 'status') status(value.message);
        else if (value.type === 'error') remoteError = value.message || 'bigki meldet einen Fehler.';
        else if (value.type === 'begin') {
          if (fd !== undefined || !Number.isSafeInteger(value.size) || value.size < 1000 || value.size > 2 * 1024 ** 3) throw new Error('Ungültige Größe der 3D-Datei.');
          expected = value.size;
          fd = fs.openSync(target, 'wx');
        } else if (value.type === 'data') {
          if (fd === undefined || expected === null || complete || typeof value.data !== 'string' || value.data.length > 300000) throw new Error('Ungültige Daten von bigki.');
          const data = Buffer.from(value.data, 'base64');
          bytes += data.length;
          if (bytes > expected) throw new Error('Die 3D-Datei ist größer als angekündigt.');
          fs.writeFileSync(fd, data);
          hash.update(data);
        } else if (value.type === 'end') {
          if (fd === undefined || complete || bytes !== expected || hash.digest('hex') !== value.sha256) throw new Error('Die 3D-Datei wurde unvollständig übertragen.');
          fs.closeSync(fd); fd = undefined;
          complete = true;
        }
      } catch (error) {
        remoteError = error.message;
        child.stdin.end();
      }
    });
    child.once('error', error => { remoteError ||= error.message; });
    child.once('close', code => {
      if (active === child) active = null;
      if (fd !== undefined) fs.closeSync(fd);
      if (cancelled) reject(new Error('Abgebrochen.'));
      else if (remoteError) reject(new Error(remoteError));
      else if (code !== 0 || !complete) reject(new Error('Verbindung zu bigki fehlgeschlagen oder unterbrochen. ' + stderr.trim().slice(-500)));
      else resolve();
    });
    child.stdin.write(JSON.stringify(request) + '\n');
  });
}

function copyUnique(source, directory) {
  fs.mkdirSync(directory, { recursive: true });
  for (let i = 1; i <= 1000; i++) {
    const name = 'KI-3D-Modell' + (i === 1 ? '' : `_${i}`) + '.blend';
    const output = path.join(directory, name);
    try {
      fs.copyFileSync(source, output, fs.constants.COPYFILE_EXCL);
      if (fs.statSync(output).size !== fs.statSync(source).size) throw new Error('Die Blender-Datei ist unvollständig.');
      return output;
    } catch (error) { if (error.code !== 'EEXIST') throw error; }
  }
  throw new Error('Kein freier Dateiname gefunden.');
}

try {
  if (!outputDir || !blender || !fs.existsSync(blender)) throw new Error('Blender wurde nicht gefunden.');
  if (!fs.existsSync(key) || !fs.existsSync(knownHosts)) throw new Error('Die Verbindung zu bigki ist auf diesem Mac noch nicht eingerichtet.');
  let raw = '';
  for await (const chunk of process.stdin) raw += chunk;
  const options = JSON.parse(raw);
  if (!['standard', 'turbo'].includes(options.model) || ![380, 768, 1024].includes(options.resolution)) throw new Error('Ungültige Einstellungen.');
  workdir = fs.mkdtempSync(path.join(os.tmpdir(), 'bilder-zu-blender-'));
  const started = Date.now();
  status('Bilder werden für bigki vorbereitet …');
  const images = {};
  for (const view of ['front', 'left', 'back', 'right']) {
    const input = options.images?.[view];
    if (!input) continue;
    let source = input;
    if (/\.(heic|heif)$/i.test(input)) {
      source = path.join(workdir, view + '.png');
      await run('/usr/bin/sips', ['-s', 'format', 'png', input, '--out', source]);
    }
    const size = fs.statSync(source).size;
    if (!size || size > 25 * 1024 * 1024) throw new Error('Jedes Bild muss kleiner als 25 MB sein.');
    images[view] = fs.readFileSync(source).toString('base64');
  }
  if (!Object.keys(images).length || (options.color && Object.keys(images).length !== 4)) throw new Error('Bitte die benötigten Bilder auswählen.');
  status('Verbindung zu bigki wird aufgebaut …');
  const glb = path.join(workdir, 'Modell.glb');
  await transfer({ operation: 'generate', model: options.model, resolution: options.resolution,
    color: options.color === true, person: options.person === true, images,
    origin: process.env.STUDIOPORTAL_ORIGIN || 'StudioPortal' }, glb);
  if (cancelled) throw new Error('Abgebrochen.');
  const blend = path.join(workdir, 'Modell.blend');
  status('Blender-Datei wird erstellt …');
  const preview = path.join(workdir, 'preview.png');
  await run(blender, ['--background', '--factory-startup', '--disable-autoexec', '--python-exit-code', '1',
    '--python', path.join(resources, 'convert.py'), '--', glb, blend], { STUDIOPORTAL_THUMBNAIL: preview });
  if (cancelled) throw new Error('Abgebrochen.');
  if (!fs.existsSync(blend) || fs.statSync(blend).size < 1000) throw new Error('Die Blender-Datei wurde nicht erstellt.');
  const saved = copyUnique(blend, outputDir);
  writeMeta(saved, { kind: 'model', source: 'images', model: options.model, resolution: options.resolution,
    color: options.color === true, person: options.person === true,
    durationSeconds: Math.round((Date.now() - started) / 1000) }, preview, options.images);
  event('done', { path: saved });
} catch (error) {
  event(cancelled ? 'cancelled' : 'error', { message: cancelled ? 'Abgebrochen.' : String(error?.message || error) });
  process.exitCode = cancelled ? 130 : 1;
} finally {
  if (workdir) try { fs.rmSync(workdir, { recursive: true, force: true }); } catch {}
}
