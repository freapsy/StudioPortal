import { createInterface } from "node:readline";

import { lstat, opendir, realpath } from "node:fs/promises";
import path from "node:path";

const files = process.argv[2] === "files";
const tools = files ? [{
  name: "list_documents",
  description: "Listet Bilder, Dokumente und Unterordner im freigegebenen Ordner. Jede Datei und jeder Ordner – auch der abgefragte Ordner selbst (folder) – hat modified (zuletzt geändert) und created (erstellt), Ortszeit; Dateien zusätzlich bytes. recursive: true durchsucht auch alle Unterordner. offset blättert weiter.",
  inputSchema: { type: "object", properties: { directory: {type: "string"}, recursive: {type: "boolean"}, offset: {type: "integer", minimum: 0} }, additionalProperties: false },
}] : [{
  name: "web_search",
  description: "Suche öffentliche Fakten bei Bing. Verwende nur kurze, öffentliche Stichwörter. Verwende keine persönlichen Angaben, Dateiinhalte oder Chatpassagen. Liefert Titel, URL und Auszug.",
  inputSchema: {
    type: "object",
    properties: { query: { type: "string", minLength: 2, maxLength: 160 } },
    required: ["query"],
    additionalProperties: false,
  },
}];

const pad = (n) => String(n).padStart(2, "0");
const stamp = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;

async function listDocuments({ directory = ".", recursive = false, offset = 0 }) {
  if (typeof directory !== "string" || path.isAbsolute(directory) || typeof recursive !== "boolean" || !Number.isSafeInteger(offset) || offset < 0)
    throw new Error("Relativen Ordner und gültigen Offset angeben.");
  const root = await realpath(process.argv[3]);
  const selected = await realpath(path.resolve(root, directory));
  const relative = path.relative(root, selected);
  if (relative === ".." || relative.startsWith(".." + path.sep)) throw new Error("Außerhalb des Arbeitsordners.");
  const found = [];
  const walk = async (folder) => {
    for await (const item of await opendir(folder)) {
      if (item.name.startsWith(".")) continue;
      const full = path.join(folder, item.name);
      if (item.isDirectory()) {
        found.push({ full, dir: true });
        if (recursive) await walk(full);  // Dirent folgt keinen Symlinks: bleibt im Arbeitsordner
      } else if (item.isFile() && /\.(psd|psb|pcraft|png|jpe?g|webp|heic|heif|tiff?|bmp|gif|pdf|avif)$/i.test(item.name)) {
        found.push({ full, dir: false });
      }
    }
  };
  await walk(selected);
  found.sort((a, b) => a.full.localeCompare(b.full));
  const own = await lstat(selected);
  const folder = { path: relative ? relative + "/" : "./", modified: stamp(own.mtime), created: stamp(own.birthtime) };
  const entries = [];
  for (const { full, dir } of found.slice(offset, offset + 80)) {
    const info = await lstat(full);
    const entry = { path: path.relative(root, full) + (dir ? "/" : ""), modified: stamp(info.mtime), created: stamp(info.birthtime) };
    if (!dir) entry.bytes = info.size;
    entries.push(entry);
  }
  return { folder, total: found.length, entries, nextOffset: found.length > offset + 80 ? offset + 80 : null };
}

function field(item, name) {
  const text = item.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`, "i"))?.[1] ?? "";
  if (text.startsWith("<![CDATA[") && text.endsWith("]]>")) return text.slice(9, -3);
  const entities = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
  return text.replace(/&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-f]+);/gi, (original, key) => {
    if (Object.hasOwn(entities, key)) return entities[key];
    const value = key.startsWith("#x") ? parseInt(key.slice(2), 16) : Number(key.slice(1));
    return Number.isInteger(value) && value <= 0x10ffff ? String.fromCodePoint(value) : original;
  });
}

async function search(value) {
  const query = typeof value === "string" ? value.trim() : "";
  if (query.length < 2 || query.length > 160 || /[\r\n\u0000-\u001f]|\S+@\S+|file:|\/(Users|home|Volumes)\//i.test(query)) {
    throw new Error("Erlaubt sind kurze öffentliche Suchbegriffe.");
  }
  const url = new URL("https://www.bing.com/search");
  url.search = new URLSearchParams({ format: "rss", q: query });
  const response = await fetch(url, { redirect: "error", signal: AbortSignal.timeout(10000) });
  if (!response.ok) throw new Error(`Die Websuche meldet HTTP ${response.status}.`);
  const xml = await response.text();
  const rows = [];
  for (const [, item] of xml.matchAll(/<item>([\s\S]*?)<\/item>/gi)) {
    const result = { title: field(item, "title"), url: field(item, "link"), snippet: field(item, "description").slice(0, 550) };
    if (/^https?:\/\//i.test(result.url) && result.title) rows.push(result);
    if (rows.length === 6) break;
  }
  if (!rows.length) throw new Error("Die Websuche hat keine lesbaren Treffer geliefert.");
  return rows;
}

for await (const line of createInterface({ input: process.stdin, crlfDelay: Infinity })) {
  let request;
  try { request = JSON.parse(line); } catch { continue; }
  if (request.id === undefined) continue;
  const reply = { jsonrpc: "2.0", id: request.id };
  if (request.method === "initialize") {
    reply.result = {
      protocolVersion: request.params.protocolVersion, capabilities: { tools: {} },
      serverInfo: { name: files ? "StudioPortal Arbeitsordner" : "StudioPortal Websuche", version: "1.0" },
    };
  } else if (request.method === "tools/list") {
    reply.result = { tools };
  } else if (request.method === "ping") {
    reply.result = {};
  } else if (request.method === "tools/call" && request.params?.name === tools[0].name) {
    try {
      reply.result = { content: [{ type: "text", text: JSON.stringify(files ? await listDocuments(request.params.arguments ?? {}) : await search(request.params.arguments?.query)) }] };
    } catch (error) {
      reply.result = { isError: true, content: [{ type: "text", text: error.message }] };
    }
  } else {
    reply.error = { code: -32601, message: "Methode nicht verfügbar" };
  }
  process.stdout.write(JSON.stringify(reply) + "\n");
}
