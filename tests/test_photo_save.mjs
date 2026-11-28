import assert from "node:assert/strict";
import { existsSync, mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import extension from "../src/pi-photocraft-save.mjs";

test("PhotoCraft confines writes and distinguishes a saved file from its template", () => {
  const base = mkdtempSync(join(tmpdir(), "studioportal-save-"));
  try {
    const root = join(base, "PhotoCraft-Ergebnisse", "Sitzung");
    const workspace = join(base, "Vorlagen");
    mkdirSync(root, { recursive: true });
    mkdirSync(workspace);
    process.env.STUDIOPORTAL_RESULTS = root;
    process.env.STUDIOPORTAL_PHOTO_WORKSPACE = workspace;
    const handlers = new Map();
    extension({ on: (name, handler) => handlers.set(name, handler) });
    const beforeTool = handlers.get("tool_call");
    const call = (tool, path) => beforeTool({ toolName: "mcp__photocraft__" + tool, input: { path } });

    assert.equal(call("doc_save"), undefined);
    assert.equal(call("doc_save", "November/Entwurf/Neu.psd"), undefined);
    assert.equal(call("doc_save", "November/Entwurf/Neu.psd"), undefined);
    assert.equal(call("doc_export", join(root, "Oktober/Neu.png")), undefined);
    assert.ok(existsSync(join(root, "November", "Entwurf")));
    assert.ok(existsSync(join(root, "Oktober")));
    assert.equal(call("doc_open", "unveraendert/Neu.psd"), undefined);
    assert.ok(!existsSync(join(root, "unveraendert")));

    const save = { toolName: "mcp__photocraft__doc_save", input: { path: "PhotoCraft-Ergebnisse/Sitzung/Jahr/Art/Person/Periode/Neu.psd" } };
    assert.equal(beforeTool(save), undefined);
    assert.equal(save.input.path, "Jahr/Art/Person/Periode/Neu.psd");
    assert.ok(existsSync(join(root, "Jahr", "Art", "Person", "Periode")));
    assert.ok(!existsSync(join(root, "PhotoCraft-Ergebnisse")));
    const output = join(root, "Neu.psd");
    const template = join(workspace, "Neu.psd");
    writeFileSync(output, "neu");
    writeFileSync(template, "alt");
    const ambiguous = call("doc_open", "Neu.psd");
    assert.equal(ambiguous.block, true);
    assert.ok(ambiguous.reason.includes(output) && ambiguous.reason.includes(template));
    assert.equal(call("doc_open", output), undefined);
    assert.equal(call("doc_open", template), undefined);
    const afterTool = handlers.get("tool_result");
    for (const path of ["Neu.psd", output]) {
      const reply = afterTool({ toolName: save.toolName, content: [{ type: "text", text: JSON.stringify({ path, warnings: [] }) }] });
      assert.deepEqual(JSON.parse(reply.content[0].text), { path, warnings: [], absolutePath: output });
    }
    assert.equal(afterTool({ toolName: save.toolName, isError: true, content: [] }), undefined);

    symlinkSync(base, join(root, "link"));
    writeFileSync(join(root, "datei"), "");
    for (const path of ["../extern/Neu.psd", join(base, "extern/Neu.psd"), "link/extern/Neu.psd",
                        "datei/Neu.psd", "November//Neu.psd", "Laufwerk:Ordner/Neu.psd"]) {
      assert.equal(call("doc_save", path)?.block, true, path);
    }
    assert.ok(!existsSync(join(base, "extern")));
  } finally {
    rmSync(base, { recursive: true, force: true });
  }
});

test("the stable result root keeps legacy paths and separates paragraph breaks from format runs", () => {
  const base = mkdtempSync(join(tmpdir(), "studioportal-stable-save-"));
  try {
    const root = join(base, "PhotoCraft-Ergebnisse");
    const legacy = "2026-11-20 18-29-39/Neu.psd";
    mkdirSync(join(root, "2026-11-20 18-29-39"), { recursive: true });
    writeFileSync(join(root, legacy), "existing");
    const checkpoint = ".studioportal-stand-session.psd";
    writeFileSync(join(root, checkpoint), "checkpoint");
    process.env.STUDIOPORTAL_RESULTS = root;
    process.env.STUDIOPORTAL_PHOTO_WORKSPACE = root;
    process.env.STUDIOPORTAL_PHOTO_CHECKPOINT = checkpoint;
    const handlers = new Map();
    extension({ on: (name, handler) => handlers.set(name, handler) });
    const call = (tool, path) => {
      const input = { path };
      const result = handlers.get("tool_call")({ toolName: "mcp__photocraft__" + tool, input });
      return { input, result };
    };
    assert.equal(call("doc_open", "PhotoCraft-Ergebnisse/" + legacy).input.path, join(root, legacy));
    assert.equal(call("doc_open", legacy).result, undefined);
    assert.equal(call("doc_save", legacy).result?.block, true);
    assert.equal(call("doc_save").result, undefined);
    assert.equal(call("doc_save", checkpoint).result, undefined);
    assert.equal(call("doc_save", "PhotoCraft-Ergebnisse/Jahr/Neu.psd").input.path, "Jahr/Neu.psd");
    assert.ok(!existsSync(join(root, "PhotoCraft-Ergebnisse")));
    const info = { text: "Eins\t\t\r\nZwei\nDrei\u2028Fortsetzung", paragraphs: [{ start: 0 }] };
    const result = handlers.get("tool_result")({ toolName: "mcp__photocraft__command_run", input: { id: "type.info" },
      content: [{ type: "text", text: JSON.stringify(info) }] });
    assert.deepEqual(JSON.parse(result.content[0].text), { ...info, paragraphCount: 3, tabsByParagraph: [2, 0, 0] });
    const batch = handlers.get("tool_result")({ toolName: "mcp__photocraft__command_batch", input: { steps: [{ id: "type.info" }] },
      content: [{ type: "text", text: JSON.stringify({ completed: 2, results: [{ ok: true, result: info }, { ok: true, result: { layer: 3 } }] }) }] });
    assert.equal(JSON.parse(batch.content[0].text).results[0].result.paragraphCount, 3);
    const inspect = handlers.get("tool_result")({ toolName: "mcp__photocraft__doc_inspect",
      content: [{ type: "text", text: JSON.stringify({ width: 120, height: 80, layers: [
        { id: 1, kind: "Type", name: "Summe", bounds: [10, 0, 115, 13] },
        { id: 2, kind: "Type", bounds: [10, 0, 110, 13] },
        { id: 3, kind: "Type", visible: false, bounds: [0, 0, 121, 13] },
        { id: 4, kind: "Pixel", bounds: [0, 0, 121, 13] },
      ] }) }] });
    assert.deepEqual(JSON.parse(inspect.content[0].text).clippedTextLayers,
      [{ id: 1, name: "Summe", bounds: [10, 0, 115, 13] }]);
    const styled = handlers.get("tool_result")({ toolName: "mcp__photocraft__command_run", input: { id: "type.setStyle" },
      content: [{ type: "text", text: JSON.stringify({ ...info, paragraphs: [{}, {}, {}] }) }] });
    assert.equal(JSON.parse(styled.content[0].text).paragraphCount, 3);
    const fullFile = join(base, "voll.txt");
    writeFileSync(fullFile, JSON.stringify({ ...info, layer: 33, lines: [{}, {}, {}] }));
    const cut = handlers.get("tool_result")({ toolName: "mcp__photocraft__command_run", input: { id: "type.info" },
      details: { fullOutputPath: fullFile }, content: [{ type: "text", text: "Warning: truncated output …" }] });
    assert.match(cut.content[0].text, /Ebene 33: paragraphCount 3 .*1 Absatzformat-Lauf.*3 Zeilen/);
    assert.equal(cut.content[1].text, "Warning: truncated output …");
    assert.equal(handlers.get("tool_result")({ toolName: "mcp__photocraft__command_run", input: { id: "layer.select" },
      content: [{ type: "text", text: "{\"layer\":3}" }] }), undefined);
  } finally {
    rmSync(base, { recursive: true, force: true });
  }
});
