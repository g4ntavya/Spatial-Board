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
import { randomUUID } from 'node:crypto';

const rds = new RDSDataClient({});
const bedrock = new BedrockRuntimeClient({});
const { CLUSTER_ARN, SECRET_ARN, DB_NAME, OCR_MODEL_ID, EMBED_MODEL_ID } = process.env;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Aurora scales to zero when idle. A queued note can arrive while the cluster is
// paused, so retry through the ~15-25s DatabaseResumingException rather than
// burning an SQS receive (3 strikes → DLQ) on a cold start.
const isResuming = (err) =>
  err?.name === 'DatabaseResumingException' || /resuming after being auto-paused/i.test(err?.message ?? '');

async function exec(sql, parameters = []) {
  const cmd = new ExecuteStatementCommand({ resourceArn: CLUSTER_ARN, secretArn: SECRET_ARN, database: DB_NAME, sql, parameters });
  for (let attempt = 1; ; attempt++) {
    try {
      return await rds.send(cmd);
    } catch (err) {
      if (!isResuming(err) || attempt >= 8) throw err;
      await sleep(Math.min(1000 * attempt, 4000)); // 1s,2s,3s,4s,4s… ≈ resume time
    }
  }
}

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
  const sx = (x) => (x - proj.minX + pad) * scale;
  const sy = (y) => (y - proj.minY + pad) * scale;
  // The iOS app smooths every stroke (Catmull-Rom + Gaussian) before syncing.
  // Drawing those points as straight segments would discard that smoothing, so we
  // re-curve them here with a Catmull-Rom spline (converted to cubic béziers) for a
  // faithful, handwriting-quality result that matches what was drawn in AR.
  const smoothPathD = (pts) => {
    const P = pts.map(([x, y]) => [sx(x), sy(y)]);
    const f = (n) => n.toFixed(1);
    if (P.length < 3) return P.map(([x, y], i) => `${i ? 'L' : 'M'}${f(x)} ${f(y)}`).join(' ');
    let d = `M${f(P[0][0])} ${f(P[0][1])}`;
    for (let i = 0; i < P.length - 1; i++) {
      const p0 = P[i === 0 ? 0 : i - 1];
      const p1 = P[i];
      const p2 = P[i + 1];
      const p3 = P[i + 2 < P.length ? i + 2 : i + 1];
      const c1x = p1[0] + (p2[0] - p0[0]) / 6, c1y = p1[1] + (p2[1] - p0[1]) / 6;
      const c2x = p2[0] - (p3[0] - p1[0]) / 6, c2y = p2[1] - (p3[1] - p1[1]) / 6;
      d += `C${f(c1x)} ${f(c1y)} ${f(c2x)} ${f(c2y)} ${f(p2[0])} ${f(p2[1])}`;
    }
    return d;
  };
  const paths = proj.polylines
    .map((pl) => {
      const d = smoothPathD(pl.pts);
      // Default/white ink follows the page theme (currentColor); explicit pen
      // colors are kept. No background rect, so light/dark paper shows through.
      const stroke = pl.color && pl.color !== 'white' ? COLORS[pl.color] ?? 'currentColor' : 'currentColor';
      return `<path d="${d}" fill="none" stroke="${stroke}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>`;
    })
    .join('');
  return { svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}">${paths}</svg>`, W, H, sx, sy };
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
// Higher resolution = noticeably better OCR.
function rasterize(proj, W = 1024) {
  const w = Math.max(proj.maxX - proj.minX, 1e-4);
  const h = Math.max(proj.maxY - proj.minY, 1e-4);
  const pad = 0.06 * Math.max(w, h);
  const scale = (W - 2) / (w + 2 * pad);
  const H = Math.max(2, Math.min(1400, Math.round((h + 2 * pad) * scale)));
  const g = Buffer.alloc(W * H, 255);
  const plot = (x, y) => {
    const xi = Math.round(x), yi = Math.round(y);
    for (let dy = -3; dy <= 3; dy++)
      for (let dx = -3; dx <= 3; dx++) {
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
const PROMPT = `You are reading a handwritten page captured in AR: dark ink strokes on a blank page. The page may hold SEVERAL unrelated pieces of content placed in different areas (for example a to-do list in one spot, a math equation in another, a stray phrase elsewhere).

Identify each DISTINCT piece of content and return it as its own entry.
- Two pieces are distinct if they are about different things (a task list vs an equation vs a random phrase) — even when they sit close together or share rows.
- Do NOT split a single coherent piece (one list, one equation, one paragraph) into multiple entries.

For each distinct piece provide:
- "type": the rendering kind — one of "todo" (tasks/checklist), "math" (numbers/equations/working), "code", "idea" (a plan/brainstorm), "text" (prose/words/names), "diagram".
- "subject": the broad SUBJECT this belongs under, used as a folder, the way a student names a binder. 1-2 words, Title Case. Infer it from the content: Newton's laws / EM waves → "Physics"; a cell diagram → "Biology"; derivatives → "Math"; a sprint plan → "Work"; groceries/errands → "Personal". Reuse the SAME subject word for related material so it lands in one folder. If truly unclear, use "Notes".
- "title": the specific TOPIC name within that subject (about 2-4 words, Title Case) — what THIS piece is. Newton's laws working → "Newton's Laws" or "NLM"; "6²=36" → "Math Solving"; a grocery list → "Grocery List". NEVER use the words handwritten, note, drawing, sketch, page, or text, and avoid clumsy literal restatements like "Power Of Six".
- For "todo": "items" = array of task strings in order, WITHOUT any leading bullet, number, dash, or checkbox.
- For every other type: "text" = the exact transcription. Preserve line breaks (use \\n), capitalization, punctuation, and math symbols (² √ Σ ∫ = ^). Read letter by letter; do not autocorrect or invent words.
- "region": [x0,y0,x1,y1] = this content's bounding box in the image as fractions 0..1 (x from left, y from top). Be reasonably tight.

Respond with ONLY this minified JSON, nothing before or after:
{"notes":[{"type":"...","subject":"...","title":"...","items":["..."],"text":"...","region":[x0,y0,x1,y1]}]}
Use "items" for to-dos and "text" otherwise. If nothing is legible, return {"notes":[]}.`;

// One multimodal pass → the list of distinct content pieces on the page.
async function segment(png) {
  const out = await bedrock.send(
    new ConverseCommand({
      modelId: OCR_MODEL_ID,
      messages: [{ role: 'user', content: [{ image: { format: 'png', source: { bytes: png } } }, { text: PROMPT }] }],
      inferenceConfig: { maxTokens: 1400, temperature: 0 },
    }),
  );
  const raw = (out.output?.message?.content ?? []).map((c) => c.text).filter(Boolean).join('\n');
  const m = raw.match(/\{[\s\S]*\}/);
  let arr = [];
  try { const j = JSON.parse(m ? m[0] : raw); arr = Array.isArray(j.notes) ? j.notes : []; } catch { arr = []; }
  return arr
    .filter((n) => n && (typeof n.text === 'string' && n.text.trim() || (Array.isArray(n.items) && n.items.length)))
    .slice(0, 8)
    .map((n) => ({
      type: n.type || 'text',
      subject: String(n.subject || 'Notes').slice(0, 40),
      title: String(n.title || 'Untitled note').slice(0, 80),
      items: Array.isArray(n.items) ? n.items.map((s) => String(s).trim()).filter(Boolean) : null,
      text: typeof n.text === 'string' ? n.text : '',
      region: Array.isArray(n.region) && n.region.length === 4 ? n.region.map(Number) : null,
    }));
}

// Reading order: top-to-bottom, then left-to-right, by each piece's region.
function orderByRegion(segs) {
  return [...segs].sort((a, b) => {
    const ra = a.region || [0, 0, 1, 1], rb = b.region || [0, 0, 1, 1];
    const dy = ra[1] - rb[1];
    return Math.abs(dy) > 0.08 ? dy : ra[0] - rb[0];
  });
}

// Center of a stroke in projected (x, -y) space — used to place it in a region.
function strokeCenter(s) {
  let minx = Infinity, miny = Infinity, maxx = -Infinity, maxy = -Infinity;
  for (const p of s.geometry?.points ?? []) {
    const x = p[0], y = -p[1];
    if (x < minx) minx = x; if (x > maxx) maxx = x;
    if (y < miny) miny = y; if (y > maxy) maxy = y;
  }
  return isFinite(minx) ? [(minx + maxx) / 2, (miny + maxy) / 2] : null;
}

// Assign every stroke to the segment whose region contains it (else the nearest
// region center). Returns one stroke array per segment, in the segments' order.
function assignStrokes(strokes, segs, bounds) {
  const W = Math.max(bounds.maxX - bounds.minX, 1e-4);
  const H = Math.max(bounds.maxY - bounds.minY, 1e-4);
  const groups = segs.map(() => []);
  for (const s of strokes) {
    const c = strokeCenter(s);
    if (!c) { groups[0].push(s); continue; }
    const nx = (c[0] - bounds.minX) / W, ny = (c[1] - bounds.minY) / H;
    let best = 0, bestScore = Infinity;
    segs.forEach((seg, i) => {
      const r = seg.region;
      let score = Infinity;
      if (r && nx >= r[0] && nx <= r[2] && ny >= r[1] && ny <= r[3]) score = -1; // inside
      else if (r) score = Math.hypot(nx - (r[0] + r[2]) / 2, ny - (r[1] + r[3]) / 2);
      if (score < bestScore) { bestScore = score; best = i; }
    });
    groups[best].push(s);
  }
  return groups;
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
    let msg;
    try {
      msg = JSON.parse(record.body);
    } catch {
      console.error('skipping malformed message:', record.body);
      continue;
    }
    // `manual` = a user-triggered re-transcribe; we re-OCR/split in place but do
    // NOT auto-merge into other notes (auto-merge only fires on freshly synced content).
    if (msg?.noteId) await processNote(msg.noteId, { manual: !!msg.manual });
  }
};

// Build the searchable / displayed text for a segment. To-dos become a markdown
// checklist (the web renders these as interactive checkboxes).
function segmentText(seg) {
  const isTodo = seg.type === 'todo' && Array.isArray(seg.items) && seg.items.length;
  const display = isTodo ? seg.items.map((it) => `- [ ] ${it}`).join('\n') : (seg.text ?? '');
  const plain = isTodo ? seg.items.join('. ') : (seg.text ?? '');
  return { display, plain, isTodo };
}

// Write a fully-enriched note. `mode` is 'update' (reuse id) or 'insert' (new row).
async function writeNote(mode, fields) {
  const { id, spaceId, folderId, title, text, category, noteType, svg, searchText, vector, status } = fields;
  const params = [
    { name: 'id', value: { stringValue: id }, typeHint: 'UUID' },
    { name: 'title', value: { stringValue: title } },
    { name: 'ocr', value: { stringValue: text } },
    { name: 'cat', value: { stringValue: category } },
    { name: 'ntype', value: { stringValue: noteType || 'text' } },
    { name: 'svg', value: { stringValue: svg } },
    { name: 'search', value: { stringValue: searchText || title } },
    { name: 'status', value: { stringValue: status } },
  ];
  const embCol = vector ? '(:emb)::vector' : 'NULL';
  if (vector) params.push({ name: 'emb', value: { stringValue: `[${vector.join(',')}]` } });

  if (mode === 'update') {
    await exec(
      `UPDATE notes SET title=:title, ocr_text=:ocr, category=:cat, note_type=:ntype, svg=:svg,
         search_vector=to_tsvector('english', :search), embedding=${embCol},
         status=:status, updated_at=now()
       WHERE id=:id`,
      params,
    );
  } else {
    params.push({ name: 'sid', value: { stringValue: spaceId }, typeHint: 'UUID' });
    params.push(folderId
      ? { name: 'fid', value: { stringValue: folderId }, typeHint: 'UUID' }
      : { name: 'fid', value: { isNull: true } });
    await exec(
      `INSERT INTO notes (id, space_id, folder_id, title, ocr_text, category, note_type, svg, search_vector, embedding, status)
       VALUES (:id, :sid, :fid, :title, :ocr, :cat, :ntype, :svg, to_tsvector('english', :search), ${embCol}, :status)`,
      params,
    );
  }
}

// cosine distance; smaller = stricter. Same-subject + below this → same topic.
const APPEND_THRESHOLD = Number(process.env.APPEND_THRESHOLD ?? 0.34);

// Closest EXISTING note in the SAME subject of this space, so new material on a
// topic folds into its note instead of spawning a duplicate. Only matches when
// the subject (folder) agrees AND the content is genuinely close.
async function nearestNote(spaceId, subject, vector, excludeIds) {
  if (!vector || !spaceId) return null;
  const r = await exec(
    `SELECT id::text AS id, (embedding <=> :v::vector) AS dist
       FROM notes
      WHERE space_id = :sid AND status = 'processed' AND embedding IS NOT NULL
        AND lower(category) = lower(:subj)
      ORDER BY embedding <=> :v::vector ASC LIMIT 4`,
    [
      { name: 'sid', value: { stringValue: spaceId }, typeHint: 'UUID' },
      { name: 'subj', value: { stringValue: subject } },
      { name: 'v', value: { stringValue: `[${vector.join(',')}]` } },
    ],
  );
  for (const rec of r.records ?? []) {
    const id = rec[0].stringValue;
    if (excludeIds.has(id)) continue;
    const d = rec[1];
    const dist = d?.doubleValue ?? d?.longValue ?? (d?.stringValue != null ? parseFloat(d.stringValue) : 1);
    return dist <= APPEND_THRESHOLD ? { id, dist } : null;
  }
  return null;
}

// Fold a segment (its strokes + text) into an existing note: move the strokes,
// combine the text, then re-render the SVG and re-embed the whole note.
async function appendToNote(targetId, seg, segStrokes) {
  for (const s of segStrokes) {
    await exec(`UPDATE strokes SET note_id = :nn WHERE id = :sid`, [
      { name: 'nn', value: { stringValue: targetId }, typeHint: 'UUID' },
      { name: 'sid', value: { stringValue: s.id }, typeHint: 'UUID' },
    ]);
  }
  const res = await exec(`SELECT geometry::text AS geo, color FROM strokes WHERE note_id = :nid`, [
    { name: 'nid', value: { stringValue: targetId }, typeHint: 'UUID' },
  ]);
  const strokes = (res.records ?? []).map((r) => ({ geometry: JSON.parse(r[0].stringValue), color: r[1]?.stringValue }));
  const proj = project(strokes);
  const svg = proj ? toSvg(proj).svg : null;

  const cur = await exec(`SELECT ocr_text, title FROM notes WHERE id = :id`, [{ name: 'id', value: { stringValue: targetId }, typeHint: 'UUID' }]);
  const prevText = cur.records?.[0]?.[0]?.stringValue ?? '';
  const title = cur.records?.[0]?.[1]?.stringValue ?? 'Untitled note';
  const { display } = segmentText(seg);
  const combined = [prevText, display].filter((t) => t && t.trim()).join('\n');
  const searchText = [title, combined.replace(/- \[[ xX]\]\s*/g, '')].filter(Boolean).join('. ');

  let vector = null;
  try { vector = await embed(searchText || title); } catch (err) { console.error('embed failed:', err?.name ?? err); }

  const params = [
    { name: 'id', value: { stringValue: targetId }, typeHint: 'UUID' },
    { name: 'ocr', value: { stringValue: combined } },
    { name: 'search', value: { stringValue: searchText || title } },
  ];
  let svgSql = '';
  if (svg) { svgSql = ', svg = :svg'; params.push({ name: 'svg', value: { stringValue: svg } }); }
  let embSql = '';
  if (vector) { embSql = ', embedding = (:emb)::vector'; params.push({ name: 'emb', value: { stringValue: `[${vector.join(',')}]` } }); }
  await exec(
    `UPDATE notes SET ocr_text = :ocr, search_vector = to_tsvector('english', :search)${svgSql}${embSql}, status='processed', updated_at = now() WHERE id = :id`,
    params,
  );
}

async function processNote(noteId, { manual = false } = {}) {
  // A note inside an app folder gets its subject from that folder — keep it.
  const meta = await exec(
    `SELECT n.space_id::text AS sid, n.folder_id::text AS fid, f.name AS fname
       FROM notes n LEFT JOIN folders f ON f.id = n.folder_id WHERE n.id = :id`,
    [{ name: 'id', value: { stringValue: noteId }, typeHint: 'UUID' }],
  );
  const spaceId = meta.records?.[0]?.[0]?.stringValue;
  const folderId = meta.records?.[0]?.[1]?.stringValue || null;
  const folderCategory = folderId ? (meta.records[0][2]?.stringValue || null) : null;

  const res = await exec(`SELECT id::text AS id, geometry::text AS geo, color FROM strokes WHERE note_id = :nid`, [
    { name: 'nid', value: { stringValue: noteId }, typeHint: 'UUID' },
  ]);
  const strokes = (res.records ?? []).map((r) => ({ id: r[0].stringValue, geometry: JSON.parse(r[1].stringValue), color: r[2]?.stringValue }));

  const proj = project(strokes);
  if (!proj) {
    await exec(`UPDATE notes SET status='processed', updated_at=now() WHERE id = :id`, [
      { name: 'id', value: { stringValue: noteId }, typeHint: 'UUID' },
    ]);
    return;
  }

  // One multimodal pass returns the distinct pieces of content + their regions.
  // Best-effort: if Bedrock is unavailable the note still renders (SVG) and stays
  // searchable by title; status 'partial' lets it be re-processed later.
  let segs = [];
  let ocrOk = false;
  try {
    segs = await segment(rasterize(proj).png);
    ocrOk = true;
  } catch (err) {
    console.error('OCR unavailable, rendering without text:', err?.name ?? err);
  }

  // Several distinct pieces → split into separate notes (assign each stroke to a
  // piece by region). Otherwise it stays one piece.
  let notes, groups;
  if (segs.length > 1) {
    const ordered = orderByRegion(segs);
    const g = assignStrokes(strokes, ordered, proj);
    notes = []; groups = [];
    ordered.forEach((seg, i) => { if (g[i].length) { notes.push(seg); groups.push(g[i]); } });
    if (!notes.length) { notes = [ordered[0]]; groups = [strokes]; }
  } else {
    notes = [segs[0] ?? { type: 'text', subject: 'Notes', title: 'Untitled note', text: '' }];
    groups = [strokes];
  }

  const status = ocrOk ? 'processed' : 'partial';
  const createdThisRun = new Set([noteId]); // never append into ourselves / our own splits
  let usedOriginal = false;

  for (let i = 0; i < notes.length; i++) {
    const seg = notes[i];
    const sproj = project(groups[i]);
    if (!sproj) continue;
    const { svg } = toSvg(sproj);
    const { display, plain } = segmentText(seg);
    const title = seg.title || 'Untitled note';
    const subject = folderCategory || seg.subject || 'Notes'; // app folder wins → stays in that folder
    const noteType = seg.type || 'text';
    const searchText = [title, plain].filter(Boolean).join('. ');

    let vector = null;
    try { vector = await embed(searchText || title); } catch (err) { console.error('embed failed:', err?.name ?? err); }

    // Context-aware append: same subject + very close embedding → fold into it.
    const match = (!manual && ocrOk) ? await nearestNote(spaceId, subject, vector, createdThisRun) : null;
    if (match) {
      await appendToNote(match.id, seg, groups[i]);
      continue; // this piece's strokes + text now live on the matched note
    }

    if (!usedOriginal) {
      // The original note row is reused for the first kept piece (its strokes already belong to it).
      await writeNote('update', { id: noteId, title, text: display, category: subject, noteType, svg, searchText, vector, status });
      usedOriginal = true;
    } else {
      const newId = randomUUID();
      await writeNote('insert', { id: newId, spaceId, folderId, title, text: display, category: subject, noteType, svg, searchText, vector, status });
      createdThisRun.add(newId);
      for (const s of groups[i]) {
        await exec(`UPDATE strokes SET note_id = :nn WHERE id = :sid`, [
          { name: 'nn', value: { stringValue: newId }, typeHint: 'UUID' },
          { name: 'sid', value: { stringValue: s.id }, typeHint: 'UUID' },
        ]);
      }
    }
  }

  // Every piece folded into other notes → the original is now empty; remove it.
  if (!usedOriginal) {
    await exec(`DELETE FROM notes WHERE id = :id`, [{ name: 'id', value: { stringValue: noteId }, typeHint: 'UUID' }]);
  }
}
