import { existsSync, lstatSync, mkdirSync, readFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join } from "node:path";

const saves = new Set(["mcp__photocraft__doc_save", "mcp__photocraft__doc_export"]);

function outputParts(root, path) {
  const relative = path.startsWith(root + "/") ? path.slice(root.length + 1) : path;
  const parts = relative.split("/");
  if (/[\\:\0]/.test(relative) || parts.some((part) => !part || part === "." || part === "..")) return;
  return parts;
}

/** Textinfos (type.info, type.setStyle, type.edit, auch in command_batch unter results[].result): `paragraphs` sind
 * Absatzformat-Läufe, gleiche Nachbarn fasst PhotoCraft zusammen. Die echte Absatzzahl kommt als `paragraphCount` dazu.
 * Gibt die gefundenen Textinfos zurück. */
export function countParagraphs(value, found = []) {
  if (!value || typeof value !== "object") return found;
  if (typeof value.text === "string" && Array.isArray(value.paragraphs)) {
    const paragraphs = value.text.split(/\r\n|[\r\n\u2029]/u);
    value.paragraphCount = paragraphs.length;
    value.tabsByParagraph = paragraphs.map((paragraph) => paragraph.split("\t").length - 1);
    found.push(value);
  }
  for (const child of Array.isArray(value) ? value : Object.values(value)) {
    if (child && typeof child === "object") countParagraphs(child, found);
  }
  return found;
}

/** Kurzfassung für Antworten, die Pi über 20 KB in der Mitte kürzt (dann ist der Text kein JSON mehr). */
export function paragraphSummary(infos) {
  return "Textinfo (vollständig ausgewertet): " + infos.map((info) =>
    `Ebene ${info.layer ?? "?"}: paragraphCount ${info.paragraphCount} (Absätze im Text), ` +
    `${info.paragraphs.length} Absatzformat-Lauf/Läufe in paragraphs, ${Array.isArray(info.lines) ? info.lines.length : "?"} Zeilen (lines), tabsByParagraph [${info.tabsByParagraph.join(", ")}]`).join("; ") +
    ". Weniger Formatläufe als Absätze bedeuten gleiche Formate, keinen Verlust.";
}

function clippedTextLayers(document) {
  const { width, height } = document;
  const clipped = [];
  function visit(layers) {
    for (const layer of layers) {
      if (layer.visible === false) continue;
      if (layer.kind === "Type" && Array.isArray(layer.bounds)) {
        const [x, y, w, h] = layer.bounds;
        if (w > 0 && h > 0 && (x < 0 || y < 0 || x + w > width || y + h > height)) {
          clipped.push({ id: layer.id, name: layer.name, bounds: layer.bounds });
        }
      }
      visit(layer.children ?? []);
    }
  }
  visit(document.layers);
  return clipped;
}

export default function (pi) {
  const root = process.env.STUDIOPORTAL_RESULTS;
  if (!root) return;
  const rootName = basename(root);
  const stableResults = rootName === "PhotoCraft-Ergebnisse";
  const checkpoint = process.env.STUDIOPORTAL_PHOTO_CHECKPOINT;
  const inputs = [process.env.STUDIOPORTAL_PHOTO_INPUT, process.env.STUDIOPORTAL_PHOTO_WORKSPACE]
    .filter((path) => path && path !== root);
  pi.on("tool_call", (event) => {
    const path = event.input?.path;
    if (typeof path !== "string") return;
    if (event.toolName === "mcp__photocraft__doc_open" && !isAbsolute(path)) {
      const parts = outputParts(root, path);
      if (stableResults && parts?.length > 1 && parts[0] === rootName) {
        event.input.path = join(root, ...parts.slice(1));
        return;
      }
      if (parts && existsSync(join(root, ...parts))) {
        const template = inputs.map((input) => join(input, ...parts)).find((file) => existsSync(file));
        if (template) return { block: true, reason: `Mehrdeutiger Pfad. Öffne die Vorlage unter "${template}" oder das Ergebnis unter "${join(root, ...parts)}".` };
      }
      return;
    }
    if (!saves.has(event.toolName)) return;

    const parts = outputParts(root, path);
    if (!parts) return { block: true, reason: "Der Dateipfad muss innerhalb des Ergebnisordners liegen." };
    if (!isAbsolute(path)) {
      if (parts.length > 1 && parts[0] === (stableResults ? rootName : basename(dirname(root)))) parts.shift();
      if (!stableResults && parts.length > 1 && parts[0] === rootName) parts.shift();
    }
    let parent = root;
    try {
      for (const part of parts.slice(0, -1)) {
        parent = join(parent, part);
        try {
          mkdirSync(parent, { mode: 0o700 });
        } catch (error) {
          if (error.code !== "EEXIST" || !lstatSync(parent).isDirectory()) throw error;
        }
      }
    } catch {
      return { block: true, reason: "Ein Unterordner konnte nicht angelegt werden. Prüfe, ob dort eine Datei oder ein symbolischer Link liegt." };
    }
    const relative = parts.join("/");
    if (stableResults && relative !== checkpoint && existsSync(join(root, ...parts))) {
      return { block: true, reason: "Diese Ergebnisdatei existiert bereits. Wähle einen neuen Namen. Zum beauftragten Aktualisieren einer vorhandenen PSD öffne ihren absoluten Pfad und nutze doc_save ohne path." };
    }
    event.input.path = relative;
  });
  pi.on("tool_result", (event) => {
    const commands = event.toolName === "mcp__photocraft__command_run" || event.toolName === "mcp__photocraft__command_batch";
    const inspect = event.toolName === "mcp__photocraft__doc_inspect";
    if ((!commands && !inspect && !saves.has(event.toolName)) || event.isError || event.content[0]?.type !== "text") return;
    try {
      const full = (commands || inspect) && event.details?.fullOutputPath;
      const result = JSON.parse(full ? readFileSync(full, "utf8") : event.content[0].text);
      if (inspect) {
        if (!Number.isFinite(result.width) || !Number.isFinite(result.height) || !Array.isArray(result.layers)) return;
        result.clippedTextLayers = clippedTextLayers(result);
        if (full) {
          const summary = { width: result.width, height: result.height, clippedTextLayers: result.clippedTextLayers };
          return { content: [{ type: "text", text: JSON.stringify(summary) }, ...event.content] };
        }
      } else if (full) {
        const infos = countParagraphs(result);
        if (!infos.length) return;
        return { content: [{ type: "text", text: paragraphSummary(infos) }, ...event.content] };
      } else if (commands) {
        if (!countParagraphs(result).length) return;
      } else {
        const parts = typeof result?.path === "string" && outputParts(root, result.path);
        if (!parts) return;
        result.absolutePath = join(root, ...parts);
      }
      return { content: [{ ...event.content[0], text: JSON.stringify(result) }, ...event.content.slice(1)] };
    } catch {
      // Preserve PhotoCraft's response if it is not a JSON result.
    }
  });
}
