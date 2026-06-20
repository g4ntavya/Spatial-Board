# SpatialBoard — spatial AR notetaking, mirrored to a searchable cloud library

Write notes by hand in 3D space on iPhone (LiDAR + hand gestures), and watch them
turn into a clean, auto-organized, semantically searchable library on the web. The
phone is the **capture device**; the web app is the **AWS-backed deliverable** that
transforms a messy spatial brain-dump into an Apple-Notes-clean, indexed library.

---

## 🔑 For reviewers — start here

| | |
| --- | --- |
| **Live web app** | https://spatial-board-notes-gantavyas-projects.vercel.app |
| **Demo email** | `demo@spatialboard.app` |
| **Demo password** | `spatial-demo-2026` |
| **Demo video (<3 min)** | https://youtu.be/NDZyi6bChMY |
| **AWS database** | Amazon **Aurora Serverless v2 (PostgreSQL)** + `pgvector` |
| **Frontend** | Next.js (App Router) on **Vercel** |

**A 60-second tour once you're signed in:**
1. The three-pane workspace lists notes captured in AR, already grouped into
   LLM-named categories and folders — no manual tagging.
2. Open any note: the original handwriting redraws itself stroke-by-stroke (an SVG
   projected from the 3D strokes), with a clean text transcription beneath it.
3. Use the search box — it runs **hybrid keyword + semantic search** over the notes,
   fused in SQL. Try a query that doesn't match the words literally.
4. Hit **⌘K** for the command palette, or open **Ask** to ask a question across all
   your notes — the answer streams token-by-token from a RAG pipeline with citations.
5. Pin, move between categories, or **Share** a note with another account.

The login persists for 30 days, so you stay signed in across visits.

<p align="center">
  <img src="WhiteBoARd/assets/img1.png" width="240" alt="Portrait AR view">
  &nbsp;
  <img src="WhiteBoARd/assets/img2.png" width="380" alt="Landscape view 1">
  <img src="WhiteBoARd/assets/img3.png" width="380" alt="Landscape view 2">
</p>

---

## The idea

Spatial notetaking is great for *thinking* and terrible for *retrieval*. You can
scatter ideas around a room in AR, but a week later you can't find anything. SpatialBoard
closes that loop: the relationship between the two layers is **transformation, not
mirroring**. The cloud does real work — spatial clustering, 2D projection, OCR,
embedding, categorization — so the chaotic 3D capture becomes a calm, queryable archive.

- **Capture (iOS):** draw, organize, and solve math in 3D with hand gestures. No stylus,
  no keyboard. Handwriting is reproduced in *your* style by an on-device engine (Kon).
- **Transform (AWS):** stroke batches are clustered into notes, projected to SVG, read by
  a vision LLM, embedded for semantic search, and titled/categorized automatically.
- **Retrieve (web):** a fast three-pane library with hybrid search, ask-your-notes RAG,
  folders, sharing, pinning, and a command palette.

---

## Architecture

End-to-end, left → right: **AR capture on iOS → AWS enrichment → web companion.**
Full source diagram (Mermaid) in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

```
┌──────────────────────┐        ┌───────────────────────────────────────────┐        ┌────────────────────┐
│  iOS — capture        │       │  AWS · us-east-1                            │        │  Vercel — Next.js   │
│                       │       │                                             │        │                     │
│  Gestures → Kon       │  POST │   API Gateway → Ingest Lambda               │        │   Workspace         │
│  ARKit + RealityKit   │ ────▶ │       (cluster strokes → notes)             │        │   search · folders  │
│  SwiftData            │ HTTPS │            │            └──▶ SQS ──▶ Process │        │   share · pin       │
│  SyncService (JWT)    │       │            ▼                      Lambda     │        │   Ask (RAG)         │
│  Live Activity        │       │      Aurora Serverless v2 ◀── OCR · embed ── │ ◀────▶ │                     │
└──────────────────────┘        │      Postgres + pgvector      title · cat   │ Data   └────────────────────┘
                                │            ▲                  (Bedrock)     │  API
                                │      Auth Lambda (JWT)                      │ (HTTP)
                                └─────────────────────────────────────────────┘
```

### The AWS cloud pipeline

The database is the center of gravity — **one Aurora PostgreSQL system** does relational
metadata, JSONB stroke blobs, full-text search, *and* vector search, so the data model
stays deliberate instead of bolting on a second store.

| Stage | Service | What it does |
| --- | --- | --- |
| Ingest | API Gateway (HTTP API) + **Ingest Lambda** | Receives stroke batches from iOS; **single-linkage clustering** (0.16 m) groups strokes into notes; in-app folders become categories; a new cluster within 0.30 m of an existing note re-joins it (write near old work days later → it appends to that note). |
| Queue | **SQS** (+ DLQ) | Decouples instant ingest from heavy enrichment. |
| Enrich | **Process Lambda** | Projects 3D strokes → smoothed 2D SVG (Catmull-Rom); **Bedrock Nova Pro** for OCR, content-aware titles, and categories; **Bedrock Titan v2** for 1024-d embeddings. |
| Store | **Aurora Serverless v2 (PostgreSQL) + pgvector** | `notes` carries a `tsvector` (keyword) *and* a `vector(1024)` column (semantic) side by side; strokes live as JSONB; folders, spaces, shares are relational. |
| Auth | **Auth Lambda** (JWT, scrypt) | Email/password identity shared with the web app via a deterministic per-email UUID. |
| Serve | **Vercel / Next.js** via **RDS Data API (HTTP)** | No VPC or connection-pooling pain from serverless functions. |

**Cost design:** Aurora scales to **zero** (min 0 ACU); Lambdas reach it over the RDS
Data API, so the VPC needs **no NAT gateway**. Idle cost is effectively nothing.

Schema: [infra/db/schema.sql](infra/db/schema.sql) · Plan & rationale: [docs/AWS_PLAN.md](docs/AWS_PLAN.md) · Deploy: [docs/DEPLOY.md](docs/DEPLOY.md)

### The web companion (Next.js on Vercel)

- **Three-pane workspace** — spaces → categories/folders → notes → detail.
- **Hybrid search** — keyword (`tsvector`) and semantic (`pgvector`) results fused with
  Reciprocal Rank Fusion *inside one SQL query*.
- **Ask your notes** — RAG: Titan embeds the question → pgvector retrieves the closest
  notes → Bedrock streams a cited answer token-by-token.
- **Handwriting playback** — each note's strokes redraw in reading order, like a pen.
- **Sharing** — share a note (handwriting, text, or both) with another account.
- **Polish** — ⌘K command palette, toasts with undo, pinning, responsive drawer,
  30-day persistent login.

Web source lives in [web/](web/); infrastructure-as-code (AWS CDK) in [infra/](infra/).

---

## Kon — the handwriting engine

Kon reproduces handwriting in the user's own style and solves math written in the air.

**On-device (shipping today):** onboarding captures A–Z letterforms; a segmentation +
OCR pipeline feeds live glyph samples from your AR strokes into per-user style profiles;
generated answers are rendered in your style with consistent cap-height layout. For math,
Kon depth-culls to the physically nearest equation slab, sends an optimized image to
Gemini, and writes the answer back into AR right next to the equation.

**Research model (in [train/](train/)):** a from-scratch **flow-matching Diffusion
Transformer** for personalized, bilingual (English + math) online handwriting synthesis —
a content encoder (letters/digits/math + 2D layout levels for fractions/super/subscripts),
a few-glyph style encoder conditioning DiT blocks via AdaLN-Zero, and a rectified-flow
sampler with classifier-free guidance emitting `[pen, Δx, Δy]` trajectories. Trained on
IAM-OnDB (English) + CROHME (math). Design notes: [train/SOTA_DESIGN.md](train/SOTA_DESIGN.md),
diagram: [train/ARCHITECTURE.md](train/ARCHITECTURE.md). (The hackathon build uses the
on-device engine; the flow model is ongoing research.)

---

## iOS app features

### Spatial canvas
- Notes anchored to real-world coordinates using ARKit WorldAnchors
- Persistent notes across sessions via SwiftData; 3D folder entities to organize in space
- Depth-aware drawing-plane locking for stable stroke placement
- Space-based isolation so each workspace shows only its own content

### Hand gesture system (Vision framework)
- **Pinch** (thumb + index): draw · **Two-hand pinch**: selection rectangle
- **Palm (while selected)**: move strokes/folders in 3D · **Pinch (while selected)**: resize
- **Open palm**: erase (disabled while selecting) · **Pointing**: folder hover open/close
- Real-time 2D hand-landmark detection with optimized 3D positioning; pinch hysteresis to
  prevent flicker; depth-aware palm/point raycasting

### Drawing
- Strokes captured as bezier curves, rendered as 3D tube meshes (RealityKit MeshResource),
  stored as world-anchored entities
- Smooth stroke start with initial-point stabilization; partial erasing with segment
  splitting and persistence; selection outlines and folder target glow during drag/drop

### Selection, move, resize, folders
- 2D selection rectangle projected from two-hand pinch into scene entities
- Palm-locked move with smoothing; billboard behavior preserved for strokes and folders
- Drag-and-drop absorption into folders by proximity; folder open/close by pointing hold

### Spaces, style matching, math
- Multiple named spatial workspaces with animated transitions; `spaceID`-scoped loading;
  swipe-to-delete
- Onboarding captures letterforms; Kon learns continuously from your AR strokes on-device
- Kon math solving with 3D equation targeting and depth culling (see above)

### Performance
- Non-blocking Vision processing on a dedicated queue; throttled, gesture-priority hand
  tracking; minimal raycast conversions; LiDAR depth at 15fps; distance culling

---

## Project structure

```
SpatialBoard/
├── WhiteBoARd/              # iOS app (capture device)
│   ├── frontend/            # SwiftUI + RealityKit AR views, onboarding, spaces
│   └── backend/             # ARSessionManager, Gemini, StrokeProcessor, Kon, gestures
├── web/                     # Next.js web companion (Vercel)
│   ├── app/                 # Workspace UI, API routes (notes, ask, share, auth)
│   └── lib/                 # Aurora Data API client, Bedrock, auth, identity
├── infra/                   # AWS CDK (TypeScript) + DB schema + Lambdas
│   ├── db/schema.sql        # Aurora schema (pgvector, tsvector, JSONB)
│   └── lambdas/             # ingest · process · auth
├── train/                   # Kon-Flow research model (flow-matching DiT)
├── landing_page/            # Marketing site
└── docs/                    # ARCHITECTURE, AWS_PLAN, DEPLOY, AUTH_SETUP
```

---

## Setup

### Web companion (the AWS deliverable)
```bash
cd web
npm install
cp .env.example .env.local   # fill in Aurora ARN/secret, AWS region, AUTH_SECRET, etc.
npm run dev
```
See [docs/DEPLOY.md](docs/DEPLOY.md) for provisioning Aurora + Lambdas via CDK and the
exact Vercel environment variables.

### iOS app
1. Open [WhiteBoARd.xcodeproj](WhiteBoARd.xcodeproj) in Xcode 17+
2. Set your development team in Signing & Capabilities
3. Configure the Gemini key (Kon math): `GEMINI_API_KEY` env var, or
   `GeminiService.shared.configure(apiKey:)`
4. Build and run on a physical iPhone Pro (LiDAR required)

---

## Requirements

| Component | Version / Requirement |
| --- | --- |
| iOS | 26.0 or later (physical iPhone with LiDAR for full AR) |
| Xcode / Swift | 17.0+ / Swift 6.0 |
| Web | Node 18+, Next.js (App Router) |
| Cloud | AWS account (Aurora Serverless v2, Bedrock, Lambda, SQS, API Gateway) + Vercel |

iOS is built as a Swift Package / Xcode app target for physical-device testing; the
simulator covers limited logic/UI flows (`#if targetEnvironment(simulator)` guards),
but AR, LiDAR, and hand-tracking require supported hardware.

## License

MIT License
