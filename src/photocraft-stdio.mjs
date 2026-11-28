import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { cornerTool, softenCorner } from "./photocraft-retouch.mjs";

const [command, ...args] = process.argv.slice(2);
const child = spawn(command, args, { stdio: ["pipe", "pipe", "inherit"] });
const queue = [];
let active;
let internal;
let sequence = 0;
const lists = new Set();
const send = (line) => child.stdin.write(line + "\n");

const reply = (message) => process.stdout.write(JSON.stringify(message) + "\n");

function call(name, args) {
  return new Promise((resolve, reject) => {
    const id = `studioportal-retouch-${++sequence}`;
    internal = { id, resolve, reject };
    send(JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } }));
  });
}

function advance() {
  if (active || !queue.length) return;
  active = queue.shift();
  const { id, line, params } = active;
  const args = params.arguments ?? {};
  const wrapped = params.name === "command_run" && args.id === cornerTool.name;
  if (params.name !== cornerTool.name && !wrapped) {
    send(line);
    return;
  }
  softenCorner(call, wrapped ? args.params ?? {} : args).then(
    (result) => reply({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(result) }] } }),
    (error) => reply({ jsonrpc: "2.0", id, result: { isError: true, content: [{ type: "text", text: error.message }] } }),
  ).finally(() => {
    active = undefined;
    advance();
  });
}

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "tools/call" && Object.hasOwn(message, "id")) {
    queue.push({ id: message.id, line, params: message.params ?? {} });
    advance();
  } else if (message.method === "notifications/cancelled") {
    const id = message.params?.requestId;
    const queued = queue.findIndex((request) => request.id === id);
    if (queued !== -1) queue.splice(queued, 1);
    // Let an in-flight call settle before the next call can touch the document.
    else if (!active || active.id !== id) send(line);
  } else {
    if (message.method === "tools/list") lists.add(message.id);
    send(line);
  }
});
input.on("close", () => child.kill());
process.on("SIGTERM", () => child.kill());
process.on("SIGINT", () => child.kill());
child.on("error", (error) => {
  console.error(error.message);
  process.exitCode = 1;
  input.close();
});
child.stdin.on("error", (error) => {
  if (error.code !== "EPIPE") console.error(error.message);
  child.kill();
});
createInterface({ input: child.stdout, crlfDelay: Infinity }).on("line", (line) => {
  const message = JSON.parse(line);
  if (internal && message.id === internal.id && ("result" in message || "error" in message)) {
    const { resolve, reject } = internal;
    internal = undefined;
    const body = message.result?.content?.find((item) => item.type === "text")?.text;
    if (message.error || message.result?.isError || body === undefined) {
      reject(new Error(message.error?.message ?? body ?? "Empty PhotoCraft response"));
    } else {
      try { resolve(JSON.parse(body)); }
      catch { reject(new Error("Invalid PhotoCraft response")); }
    }
    return;
  }
  if (lists.delete(message.id) && Array.isArray(message.result?.tools)) {
    message.result.tools.push(cornerTool);
    reply(message);
  } else {
    process.stdout.write(line + "\n");
  }
  if (active && message.id === active.id && ("result" in message || "error" in message)) {
    active = undefined;
    advance();
  }
});
child.on("close", (code) => {
  process.exitCode = code ?? 1;
  input.close();
  process.stdin.destroy();
});
