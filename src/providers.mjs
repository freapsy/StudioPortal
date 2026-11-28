import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';

const UUID = /[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/i;
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

async function json(url, { signal, method = 'GET', body } = {}) {
  const res = await fetch(url, { method, signal, headers: { 'User-Agent': UA, 'Accept': 'application/json', ...(body ? { 'Content-Type': 'application/json' } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}) });
  if (!res.ok) throw new Error(`Die Plattform antwortet mit HTTP ${res.status}.`);
  return res.json();
}

function safePath(root, relative) {
  if (typeof relative !== 'string' || !relative || path.isAbsolute(relative) || relative.includes('\\')) throw new Error('Ungültiger Dateipfad im Modell.');
  const out = path.resolve(root, relative);
  if (!out.startsWith(path.resolve(root) + path.sep)) throw new Error('Ungültiger Dateipfad im Modell.');
  return out;
}

async function save(url, target, signal, expectedSize) {
  const source = new URL(url);
  if (source.protocol !== 'https:') throw new Error('Der Download-Link ist nicht sicher.');
  const res = await fetch(source, { signal, headers: { 'User-Agent': UA } });
  if (!res.ok || !res.body) throw new Error(`Die Modelldatei konnte nicht geladen werden (HTTP ${res.status}).`);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  await pipeline(Readable.fromWeb(res.body), fs.createWriteStream(target, { flags: 'wx' }), { signal });
  if (expectedSize && fs.statSync(target).size !== Number(expectedSize)) throw new Error('Eine Modelldatei wurde unvollständig heruntergeladen.');
  return target;
}

async function polyHaven(url, ctx) {
  const match = url.pathname.match(/^\/(?:a|model)\/([a-z0-9_-]+)\/?$/i);
  if (!match) throw new Error('Bitte einen Poly-Haven-Modelllink öffnen und kopieren.');
  const id = match[1];
  const files = await json(`https://api.polyhaven.com/files/${encodeURIComponent(id)}`, ctx);
  let asset = null;
  for (const kind of ['gltf', 'blend']) {
    for (const resolution of ['2k', '4k', '1k', '8k']) {
      if (files[kind]?.[resolution]?.[kind]) { asset = files[kind][resolution][kind]; break; }
    }
    if (asset) break;
  }
  if (!asset?.url) throw new Error('Für dieses Poly-Haven-Element wurde keine 3D-Datei gefunden.');
  const root = path.join(ctx.workdir, 'polyhaven');
  fs.mkdirSync(root, { recursive: true });
  const base = path.basename(new URL(asset.url).pathname);
  await save(asset.url, safePath(root, base), ctx.signal, asset.size);
  for (const [relative, item] of Object.entries(asset.include || {})) {
    if (ctx.signal.aborted) throw new Error('Abgebrochen.');
    if (!item?.url) continue;
    await save(item.url, safePath(root, relative), ctx.signal, item.size);
  }
  return { source: path.join(root, base), name: id };
}

async function blendkit(url, ctx) {
  const id = url.pathname.match(UUID)?.[0];
  if (!id) throw new Error('Im Blendkit-Link wurde keine Modell-ID gefunden.');
  const q = new URL('https://www.blenderkit.com/api/v1/search/');
  q.searchParams.set('query', `asset_base_id:${id}`);
  q.searchParams.set('dict_parameters', '1');
  const found = await json(q, ctx);
  let model = found.results?.[0];
  if (!model) {
    try { model = await json(`https://www.blenderkit.com/api/v1/assets/${id}/`, ctx); } catch { /* no matching version */ }
  }
  if (!model || model.assetType !== 'model') throw new Error('Dieses Blendkit-Element ist kein verfügbares 3D-Modell.');
  if (!model.isFree) throw new Error('Dieses Blendkit-Modell benötigt ein Konto bzw. Abo. Lade es dort herunter und wähle anschließend die Datei aus.');
  const file = model.files?.find(f => f.fileType === 'gltf') || model.files?.find(f => f.fileType === 'blend');
  if (!file?.downloadUrl) throw new Error('Für dieses Blendkit-Modell ist keine unterstützte Datei verfügbar.');
  const requestUrl = new URL(file.downloadUrl);
  if (!['www.blenderkit.com', 'www.blendkit.com'].includes(requestUrl.hostname)) throw new Error('Unbekannter Blendkit-Downloadserver.');
  requestUrl.searchParams.set('scene_uuid', crypto.randomUUID());
  const response = await json(requestUrl, ctx);
  const address = response.filePath || response.filePaths?.[0]?.url;
  if (!address) throw new Error('Blendkit hat keinen Download-Link zurückgegeben.');
  const ext = file.fileType === 'gltf' ? '.glb' : '.blend';
  const target = path.join(ctx.workdir, 'blendkit' + ext);
  await save(address, target, ctx.signal, file.fileUploadSize);
  return { source: target, name: model.name || 'Modell' };
}

async function graphql(query, variables, ctx) {
  const res = await json('https://api.printables.com/graphql/', { ...ctx, method: 'POST', body: { query, variables } });
  if (res.errors?.length) throw new Error(res.errors[0].message || 'Die Printables-Anfrage ist fehlgeschlagen.');
  return res.data;
}

async function printables(url, ctx) {
  const match = url.pathname.match(/^\/model\/(\d+)(?:[-/]|$)/);
  if (!match) throw new Error('Bitte einen Printables-Modelllink eingeben.');
  const id = match[1];
  const data = await graphql('query Model($id: ID!) { print(id: $id) { id name stls { id name fileSize } otherFiles { id name fileSize } } }', { id }, ctx);
  const model = data?.print;
  if (!model) throw new Error('Dieses Printables-Modell wurde nicht gefunden.');
  const accepted = /\.(stl|3mf|obj|fbx|glb|gltf|blend|ply|zip)$/i;
  const candidates = [...(model.stls || []).map(f => ({ ...f, kind: 'stl' })), ...(model.otherFiles || []).map(f => ({ ...f, kind: 'other' }))].filter(f => accepted.test(f.name || ''));
  if (!candidates.length) throw new Error('Für dieses Modell gibt es keine unterstützte 3D-Datei.');
  const root = path.join(ctx.workdir, 'printables'); fs.mkdirSync(root, { recursive: true });
  let loaded = 0;
  for (const file of candidates) {
    const response = await graphql('mutation Link($id: ID!, $printId: ID!, $fileType: DownloadFileTypeEnum!, $source: DownloadSourceEnum!) { getDownloadLink(id: $id, printId: $printId, fileType: $fileType, source: $source) { ok errors { messages } output { link } } }', { id: file.id, printId: id, fileType: file.kind, source: 'model_detail' }, ctx);
    const link = response?.getDownloadLink?.output?.link;
    if (!response?.getDownloadLink?.ok || !link) throw new Error('Printables benötigt für diese Datei eine Anmeldung oder Berechtigung.');
    const filename = path.basename(file.name).replace(/[^a-zA-Z0-9._-]/g, '_') || `Modell_${loaded}.stl`;
    const local = path.join(root, `${String(loaded).padStart(3, '0')}_${filename}`);
    await save(link, local, ctx.signal, file.fileSize);
    loaded++;
  }
  return { source: root, name: model.name || `Printables_${id}` };
}

async function fab(url, ctx) {
  const listingId = url.pathname.match(UUID)?.[0]?.toLowerCase();
  if (!listingId) throw new Error('Im Fab-Link wurde keine Angebots-ID gefunden.');
  const listing = await json(`https://www.fab.com/i/listings/${listingId}`, ctx);
  if (!listing?.title) throw new Error('Dieses Fab-Angebot wurde nicht gefunden.');
  // A migrated listing can have an identical public Sketchfab source.
  const search = new URL('https://api.sketchfab.com/v3/search');
  search.searchParams.set('type', 'models'); search.searchParams.set('q', listing.title); search.searchParams.set('count', '24');
  const data = await json(search, ctx);
  const candidates = (data.results || []).slice(0, 24);
  const normalized = listing.title.trim().toLowerCase();
  candidates.sort((a,b) => Number(b.name?.trim().toLowerCase() === normalized) - Number(a.name?.trim().toLowerCase() === normalized));
  for (let i = 0; i < candidates.length; i += 4) {
    const batch = await Promise.all(candidates.slice(i, i + 4).map(async item => {
      try { return await json(`https://sketchfab.com/i/models/${item.uid}`, ctx); } catch { return null; }
    }));
    const original = batch.find(item => item?.fabMigrationListingId?.toLowerCase() === listingId);
    if (original) return ctx.sketchfab(original.uid);
  }
  throw new Error('Diese Fab-Vorschau wird noch nicht unterstützt. Lade die Datei auf Fab herunter und wähle sie anschließend aus.');
}

export async function acquire(input, ctx) {
  const value = String(input || '').trim();
  if (value.startsWith('file://')) {
    const source = fileURLToPath(value);
    if (!fs.existsSync(source)) throw new Error('Die ausgewählte Datei wurde nicht gefunden.');
    return { source, name: path.basename(source).replace(/\.[^.]+$/, '') };
  }
  let url;
  try { url = new URL(/^https?:\/\//i.test(value) ? value : 'https://' + value); }
  catch { throw new Error('Bitte einen gültigen Modell-Link eingeben.'); }
  if (!['https:', 'http:'].includes(url.protocol)) throw new Error('Bitte einen gültigen Modell-Link eingeben.');
  const host = url.hostname.toLowerCase().replace(/^www\./, '');
  if (host === 'sketchfab.com') {
    const id = url.pathname.match(/[0-9a-f]{32}(?![0-9a-f])/ig)?.at(-1);
    if (!id) throw new Error('Im Sketchfab-Link wurde keine Modell-ID gefunden.');
    return ctx.sketchfab(id.toLowerCase());
  }
  if (host === 'polyhaven.com') return polyHaven(url, ctx);
  if (host === 'blenderkit.com' || host === 'blendkit.com') return blendkit(url, ctx);
  if (host === 'printables.com') return printables(url, ctx);
  if (host === 'fab.com') return fab(url, ctx);
  if (host === 'cgtrader.com' || host === 'turbosquid.com') throw new Error('Bitte lade die Datei auf der Website herunter und wähle sie anschließend mit „Datei auswählen“ aus.');
  if (/\.(glb|gltf|stl|obj|fbx|blend|ply|3mf|zip)$/i.test(url.pathname)) {
    const name = path.basename(url.pathname);
    const target = path.join(ctx.workdir, name.replace(/[^a-zA-Z0-9._-]/g, '_'));
    await save(url.href, target, ctx.signal);
    return { source: target, name: name.replace(/\.[^.]+$/, '') };
  }
  throw new Error('Dieser Link wird nicht unterstützt. Wähle stattdessen eine heruntergeladene 3D-Datei aus.');
}
