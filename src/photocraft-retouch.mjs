export const cornerTool = {
  name: "layer_soften_corner",
  description: "Partially erase one inked corner of a visible pixel layer with a single soft dab. Finds visible ink and verifies the alpha reduction. Use on the copy before rotating or moving it.",
  inputSchema: {
    type: "object",
    properties: {
      layer: { type: "integer", description: "Current ID of the visible pixel layer to edit" },
      corner: { type: "string", enum: ["topLeft", "topRight", "bottomLeft", "bottomRight"], default: "topLeft" },
      opacity: { type: "number", minimum: 0.05, maximum: 0.4, default: 0.25 },
    },
    required: ["layer"],
    additionalProperties: false,
  },
};

export async function softenCorner(call, { layer, corner = "topLeft", opacity = 0.25 }) {
  if (!Number.isInteger(layer) || !cornerTool.inputSchema.properties.corner.enum.includes(corner) ||
      !Number.isFinite(opacity) || opacity < 0.05 || opacity > 0.4) {
    throw new Error("Pass a current pixel layer ID, a corner and opacity in 0.05–0.4.");
  }
  const doc = await call("doc_inspect", {});
  function find(layers) {
    for (const item of layers) {
      if (item.visible === false) continue;
      if (item.id === layer) return item;
      const child = find(item.children ?? []);
      if (child) return child;
    }
  }
  const target = find(doc.layers);
  if (target?.kind !== "Pixel" || !target.bounds) throw new Error("Select a visible pixel layer.");
  const [x, y, width, height] = target.bounds;
  const shortSide = Math.min(width, height);
  const size = Math.min(40, Math.floor(shortSide * 0.42));
  if (size < 2) throw new Error("The pixel layer is too small for a localized dab.");
  const right = corner.endsWith("Right"), bottom = corner.startsWith("bottom");
  const x0 = Math.round(right ? x + width - 1 : x);
  const y0 = Math.round(bottom ? y + height - 1 : y);
  const command = (id, params) => call("command_run", { id, params });
  await command("layer.select", { layer });
  const alpha = async (px, py) => (await command("document.sampleColor", {
    x: px, y: py, size: 1, sampleLayer: "current",
  }))[3];
  const step = Math.max(1, Math.floor(size / 8));
  const searchRadius = Math.min(72, Math.floor(shortSide * 0.75));
  for (let radius = 0; radius <= searchRadius; radius += step) {
    for (let dx = 0; dx <= radius; dx += step) {
      const dy = radius - dx;
      const px = x0 + (right ? -dx : dx), py = y0 + (bottom ? -dy : dy);
      if (px < 0 || py < 0 || px >= doc.width || py >= doc.height) continue;
      const before = await alpha(px, py);
      if (!Number.isFinite(before) || before < 0.45) continue;
      await command("paint.stroke", {
        points: [[px, py, 1]], erase: true, target: "pixels", size, hardness: 0.25, opacity,
      });
      const after = await alpha(px, py);
      if (!Number.isFinite(after) || before - after < 0.02) throw new Error("PhotoCraft did not confirm a decrease in corner opacity.");
      return { layer, corner, point: [px, py], size, opacity, alphaBefore: before, alphaAfter: after };
    }
  }
  throw new Error("No ink was found near that corner. Try a different corner.");
}
