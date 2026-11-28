import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { once } from "node:events";
import test from "node:test";

test("parallel close, open and inspect reach the document server in order", { timeout: 3000 }, async () => {
  const server = `
    const { createInterface } = require("node:readline");
    let active = "A";
    createInterface({ input: process.stdin }).on("line", (line) => {
      const { id, params } = JSON.parse(line);
      setTimeout(() => {
        if (params.name === "doc_close") active = null;
        if (params.name === "doc_open") active = "B";
        console.log(JSON.stringify({ jsonrpc: "2.0", id, result: active }));
      }, params.name === "doc_close" ? 40 : 0);
    });
  `;
  const proxy = new URL("../src/photocraft-stdio.mjs", import.meta.url);
  const child = spawn(process.execPath, [decodeURIComponent(proxy.pathname), process.execPath, "-e", server]);
  try {
    const replies = createInterface({ input: child.stdout });
    for (const [index, name] of ["doc_close", "doc_open", "doc_inspect"].entries()) {
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: index, method: "tools/call", params: { name } }) + "\n");
    }
    const actual = [];
    for await (const line of replies) {
      const { id, result } = JSON.parse(line);
      actual.push([id, result]);
      if (actual.length === 3) break;
    }
    assert.deepEqual(actual, [[0, null], [1, "B"], [2, "B"]]);
  } finally {
    child.stdin.end();
    if (child.exitCode === null && child.signalCode === null) await once(child, "close");
  }
});

test("corner retouch skips transparent pixels and verifies partial erasure", async () => {
  const { softenCorner } = await import("../src/photocraft-retouch.mjs");
  let stroke;
  let changed = true;
  const call = async (tool, args) => {
    if (tool === "doc_inspect") return {
      width: 100, height: 100,
      layers: [{ id: 8, kind: "Pixel", visible: true, bounds: [10, 20, 50, 30] }],
    };
    if (args.id === "layer.select") return { layer: args.params.layer };
    if (args.id === "paint.stroke") {
      stroke = args.params;
      return { damage: [10, 20, 20, 20] };
    }
    assert.equal(args.id, "document.sampleColor");
    assert.equal(args.params.sampleLayer, "current");
    return [0, 0, 0, args.params.x === 15 && args.params.y === 22 ? (stroke && changed ? 0.75 : 1) : 0];
  };
  const result = await softenCorner(call, { layer: 8 });
  assert.deepEqual(stroke.points, [[15, 22, 1]]);
  assert.equal(stroke.erase, true);
  assert.deepEqual([result.alphaBefore, result.alphaAfter], [1, 0.75]);
  changed = false;
  await assert.rejects(softenCorner(call, { layer: 8 }), /did not confirm/);
});
