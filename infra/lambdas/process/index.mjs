// Process Lambda — SQS-triggered note enrichment.
//
// For each note: load its strokes, project them to a 2D SVG, rasterize that to
// a PNG (pure Node zlib, no native deps), have Bedrock Claude OCR the image and
// propose a title + category, embed the text with Titan v2, and write it all
// back to Aurora. This is the step that turns raw geometry into a searchable note.

import { RDSDataClient, ExecuteStatementCommand } from '@aws-sdk/client-rds-data';
import {
  BedrockRuntimeClient,
  ConverseCommand,
  InvokeModelCommand,
} from '@aws-sdk/client-bedrock-runtime';
import zlib from 'zlib';

const rds = new RDSDataClient({});
const bedrock = new BedrockRuntimeClient({});
const { CLUSTER_ARN, SECRET_ARN, DB_NAME, CLAUDE_MODEL_ID, EMBED_MODEL_ID } = process.env;

const exec = (sql, parameters = []) =>
  rds.send(new ExecuteStatementCommand({ resourceArn: CLUSTER_ARN, secretArn: SECRET_ARN, database: DB_NAME, sql, parameters }));

// ── 2D projection (drop Z; AR Y is up, so flip for screen space) ─────────────
function project(strokes) {
  const polylines = [];
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const s of strokes) {
    const pts = (s.geometry?.points ?? []).map((p) => [p[0], -p[1]]);
    if (pts.length < 2) continue;
    for (const [x, y] of pts) {
      minX = Math.min(minX, x); minY = Math.min(minY, y);
      maxX = Math.max(maxX, x); maxY = Math.max(maxY, y);
    }
    polylines.push({ pts, color: s.color ?? 'white' });
  }
  if (!polylines.length) return null;
  return { polylines, minX, minY, maxX, maxY };
}

const COLORS = { white: '#111', blue: '#2a5fd9', green: '#23922f', yellow: '#b58a00', red: '#cc2222', purple: '#7a30cc' };

function toSvg(proj, W = 1000) {
  const w = Math.max(proj.maxX - proj.minX, 1e-4);
  const h = Math.max(proj.maxY - proj.minY, 1e-4);
  const pad = 0.06 * Math.max(w, h);
  const scale = (W - 2) / (w + 2 * pad);
  const H = Math.round((h + 2 * pad) * scale);
  const sx = (x) => ((x - proj.minX + pad) * scale).toFixed(1);
  const sy = (y) => ((y - proj.minY + pad) * scale).toFixed(1);
  const paths = proj.polylines
    .map((pl) => {
      const d = pl.pts.map(([x, y], i) => `${i ? 'L' : 'M'}${sx(x)} ${sy(y)}`).join(' ');
      return `<path d="${d}" fill="none" stroke="${COLORS[pl.color] ?? '#111'}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>`;
    })
    .join('');
  return { svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}"><rect width="${W}" height="${H}" fill="#fff"/>${paths}</svg>`, W, H, sx, sy };
}

// ── Minimal 8-bit grayscale PNG encoder (Node built-ins only) ────────────────
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const typeBuf = Buffer.from(type, 'ascii');
  const body = Buffer.concat([typeBuf, data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}
function encodePng(gray, W, H) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4);
  ihdr[8] = 8; ihdr[9] = 0; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0; // grayscale
  const raw = Buffer.alloc((W + 1) * H);
  for (let y = 0; y < H; y++) {
    raw[y * (W + 1)] = 0; // filter: none
    gray.copy(raw, y * (W + 1) + 1, y * W, y * W + W);
  }
  const idat = zlib.deflateSync(raw, { level: 6 });
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0))]);
}

// Rasterize polylines into a grayscale buffer (black ink on white).
function rasterize(proj, W = 768) {
  const w = Math.max(proj.maxX - proj.minX, 1e-4);
  const h = Math.max(proj.maxY - proj.minY, 1e-4);
  const pad = 0.06 * Math.max(w, h);
  const scale = (W - 2) / (w + 2 * pad);
  const H = Math.max(2, Math.min(1400, Math.round((h + 2 * pad) * scale)));
  const g = Buffer.alloc(W * H, 255);
  const plot = (x, y) => {
    const xi = Math.round(x), yi = Math.round(y);
    for (let dy = -2; dy <= 2; dy++)
      for (let dx = -2; dx <= 2; dx++) {
        const px = xi + dx, py = yi + dy;
        if (px >= 0 && px < W && py >= 0 && py < H) g[py * W + px] = 0;
      }
  };
  const map = ([x, y]) => [(x - proj.minX + pad) * scale, (y - proj.minY + pad) * scale];
  for (const pl of proj.polylines) {
    let prev = null;
    for (const p of pl.pts) {
      const [x, y] = map(p);
      if (prev) {
        const steps = Math.max(1, Math.ceil(Math.hypot(x - prev[0], y - prev[1])));
        for (let i = 0; i <= steps; i++) plot(prev[0] + ((x - prev[0]) * i) / steps, prev[1] + ((y - prev[1]) * i) / steps);
      }
      prev = [x, y];
    }
  }
  return { png: encodePng(g, W, H), W, H };
}

// ── Bedrock ──────────────────────────────────────────────────────────────────
const PROMPT = `This image is a handwritten note captured in AR space. Transcribe the handwriting as accurately as you can. Then classify it.
Reply with ONLY a JSON object, no prose:
{"text": "<verbatim transcription, or \\"\\" if illegible>", "title": "<concise title, max 6 words>", "category": "<one of: Math, Notes, To-do, Diagram, Idea, Code, Other>"}`;

async function describe(png) {
  const out = await bedrock.send(
    new ConverseCommand({
      modelId: CLAUDE_MODEL_ID,
      messages: [{ role: 'user', content: [{ image: { format: 'png', source: { bytes: png } } }, { text: PROMPT }] }],
      inferenceConfig: { maxTokens: 600, temperature: 0 },
    }),
  );
  const text = (out.output?.message?.content ?? []).map((c) => c.text).filter(Boolean).join('\n');
  const m = text.match(/\{[\s\S]*\}/);
  try {
    const j = JSON.parse(m ? m[0] : text);
    return { text: j.text ?? '', title: j.title || 'Untitled note', category: j.category || 'Other' };
  } catch {
    return { text: '', title: 'Untitled note', category: 'Other' };
  }
}

async function embed(text) {
  const r = await bedrock.send(
    new InvokeModelCommand({
      modelId: EMBED_MODEL_ID,
      contentType: 'application/json',
      accept: 'application/json',
      body: JSON.stringify({ inputText: text.slice(0, 8000) }),
    }),
  );
  return JSON.parse(Buffer.from(r.body).toString()).embedding; // 1024 floats
}

// ── Handler ───────────────────────────────────────────────────────────────────
export const handler = async (event) => {
  for (const record of event.Records ?? []) {
    const { noteId } = JSON.parse(record.body);
    if (noteId) await processNote(noteId);
  }
};

async function processNote(noteId) {
  const res = await exec(`SELECT geometry::text AS geo, color FROM strokes WHERE note_id = :nid`, [
    { name: 'nid', value: { stringValue: noteId }, typeHint: 'UUID' },
  ]);
  const strokes = (res.records ?? []).map((r) => ({ geometry: JSON.parse(r[0].stringValue), color: r[1]?.stringValue }));

  const proj = project(strokes);
  if (!proj) {
    await exec(`UPDATE notes SET status='processed', updated_at=now() WHERE id = :id`, [
      { name: 'id', value: { stringValue: noteId }, typeHint: 'UUID' },
    ]);
    return;
  }

  const { svg } = toSvg(proj);

  // OCR + classify via Claude — best-effort. If Bedrock/Marketplace isn't ready,
  // the note still renders (SVG) and stays searchable by title; we mark it
  // 'partial' so it can be re-processed once Claude is available.
  let text = '';
  let title = 'Untitled note';
  let category = 'Other';
  let ocrOk = false;
  try {
    ({ text, title, category } = await describe(rasterize(proj).png));
    ocrOk = true;
  } catch (err) {
    console.error('OCR unavailable, rendering without text:', err?.name ?? err);
  }

  const searchText = [title, text].filter(Boolean).join('. ');

  // Titan embedding is Amazon-native (independent of the Claude subscription).
  let vector = null;
  try {
    vector = await embed(searchText || title);
  } catch (err) {
    console.error('embed failed:', err?.name ?? err);
  }

  const params = [
    { name: 'id', value: { stringValue: noteId }, typeHint: 'UUID' },
    { name: 'title', value: { stringValue: title } },
    { name: 'ocr', value: { stringValue: text } },
    { name: 'category', value: { stringValue: category } },
    { name: 'svg', value: { stringValue: svg } },
    { name: 'search', value: { stringValue: searchText || title } },
    { name: 'status', value: { stringValue: ocrOk ? 'processed' : 'partial' } },
  ];
  let embedSql = '';
  if (vector) {
    embedSql = ', embedding = (:emb)::vector';
    params.push({ name: 'emb', value: { stringValue: `[${vector.join(',')}]` } });
  }

  await exec(
    `UPDATE notes SET
       title = :title, ocr_text = :ocr, category = :category, svg = :svg,
       search_vector = to_tsvector('english', :search)${embedSql},
       status = :status, updated_at = now()
     WHERE id = :id`,
    params,
  );
}
