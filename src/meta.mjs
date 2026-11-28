import fs from 'node:fs';
import path from 'node:path';

// Library information next to a saved .blend: <folder>/.studioportal/<name>/{info.json, preview.png, input-*.png}
export function writeMeta(blend, info, preview, inputs = {}) {
  try {
    const folder = path.join(path.dirname(blend), '.studioportal', path.basename(blend, '.blend'));
    fs.mkdirSync(folder, { recursive: true });
    const record = { ...info, file: path.basename(blend), date: new Date().toISOString(),
      origin: process.env.STUDIOPORTAL_ORIGIN || 'StudioPortal', inputs: {} };
    if (preview && fs.existsSync(preview)) fs.copyFileSync(preview, path.join(folder, 'preview.png'));
    for (const [view, source] of Object.entries(inputs)) {
      if (!source || !fs.existsSync(source)) continue;
      const name = `input-${view}${path.extname(source).toLowerCase() || '.png'}`;
      fs.copyFileSync(source, path.join(folder, name));
      record.inputs[view] = name;
    }
    fs.writeFileSync(path.join(folder, 'info.json'), JSON.stringify(record, null, 2));
  } catch (error) {
    process.stdout.write(JSON.stringify({ type: 'notice', message: 'Verlaufseintrag konnte nicht gespeichert werden: ' + error.message }) + '\n');
  }
}
