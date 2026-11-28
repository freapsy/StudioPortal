// StudioPortal-Modus „Fragen“: Pi fragt vor jedem Befehl, der Dateien ändern, verschieben oder löschen könnte, und vor
// Änderungen an Dateien außerhalb des Ergebnisordners. Die App zeigt die Rückfrage (extension_ui_request „confirm“).
// Nur lesende Einzelbefehle laufen ohne Rückfrage. Die Sandbox (kein Netz, Schreiben nur im Arbeitsordner) gilt weiter.

const READ_ONLY = new Set(["ls", "cat", "head", "tail", "wc", "stat", "file", "du", "df", "grep", "egrep", "rg", "find",
  "mdls", "pwd", "echo", "basename", "dirname", "realpath", "sort", "uniq", "date", "tree", "sips", "exiftool", "md5", "shasum"]);

/** true, wenn der bash-Befehl sicher nur liest: ein einzelner Befehl ohne Umleitung, Verkettung oder Ersetzung. */
export function readOnly(command) {
  const text = String(command ?? "").trim();
  if (!text || /[;&|<>`\n]|\$\(/.test(text)) return false;
  const words = text.split(/\s+/);
  const program = words[0].split("/").pop();
  if (!READ_ONLY.has(program)) return false;
  if (program === "find" && words.some((w) => /^-(delete|exec|execdir|ok|okdir|fprint\w*|fls)$/.test(w))) return false;
  if (program === "sips" && words.some((w) => /^(-s|--set\w*|-[rcz]|--rotate|--resample\w*|--crop\w*|--pad\w*|-o|--out)$/.test(w))) return false;
  if (program === "exiftool" && words.some((w) => /^-[A-Za-z0-9:]+=|^-(overwrite_original|o|w)/.test(w))) return false;
  if (program === "sort" && words.some((w) => /^(-o|--output)/.test(w))) return false;
  return true;
}

export default function (pi) {
  const results = process.env.STUDIOPORTAL_RESULTS ?? "";
  pi.on("tool_call", async (event, ctx) => {
    let title, detail;
    if (event.toolName === "bash" && !readOnly(event.input?.command)) {
      title = "Befehl ausführen?";
      detail = String(event.input?.command ?? "");
    } else if ((event.toolName === "write" || event.toolName === "edit") && !(results && String(event.input?.path ?? "").startsWith(results + "/"))) {
      title = event.toolName === "write" ? "Datei schreiben?" : "Datei ändern?";
      detail = String(event.input?.path ?? "");
    } else {
      return;
    }
    const ok = await ctx.ui.confirm(title, detail);
    if (ok) return;
    // „Nein, und sag, was stattdessen“: die App liefert den Hinweis des Nutzers als Eingabe nach.
    const instead = String((await ctx.ui.input("Was soll er stattdessen tun?", "")) ?? "").trim();
    return { block: true, reason: instead
      ? `Der Nutzer hat das abgelehnt und sagt: ${instead}`
      : "Der Nutzer hat das abgelehnt. Nicht erneut versuchen; frage nach, was stattdessen passieren soll." };
  });
}
