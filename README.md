# SpatialBoard

Write notes by hand in the air. Your iPhone catches them in 3D space (LiDAR + hand
gestures, no stylus, no keyboard), and the cloud quietly turns that beautiful mess into
a clean, searchable library you can actually find things in later. The phone is where
you think. The web app is where it all gets remembered.

---

## 🔑 Reviewers, start here

| | |
| --- | --- |
| **Live web app** | https://spatial-board-notes.vercel.app |
| **Demo email** | `demo@spatialboard.app` |
| **Demo password** | `spatial-demo-2026` |
| **Demo video (under 3 min)** | https://youtu.be/sIWVNEsMZm8 |
| **AWS database** | Amazon **Aurora Serverless v2 (PostgreSQL)** + `pgvector` |
| **Frontend** | Next.js (App Router) on **Vercel** |

**60 seconds, signed in, here's the vibe:**
1. Three panes. Notes you scribbled in AR show up already split by topic and filed into
   subject folders the AI named for you. Zero manual tagging. You did nothing. Nice.
2. Tap a note. Your actual handwriting redraws itself stroke by stroke (it's an SVG
   projected out of the 3D strokes), with a transcription designed for what it is below:
   tickable checkboxes for to-dos, an equation card for math, a code block for code.
3. Search something. It's hybrid keyword + semantic, fused in one SQL query, so it gets
   what you *meant* even if you typed the wrong words.
4. Hit **⌘K** for the command palette, or smash **Ask** to question your whole brain
   dump. The answer streams in token by token, with receipts (citations).
5. Pin it, move it, or **Share** it with another account.

Login sticks around for 30 days, so you're not retyping that password every time.

<p align="center">
  <img src="WhiteBoARd/assets/img1.png" width="240" alt="Portrait AR view">
  &nbsp;
  <img src="WhiteBoARd/assets/img2.png" width="380" alt="Landscape view 1">
  <img src="WhiteBoARd/assets/img3.png" width="380" alt="Landscape view 2">
</p>

---

## The idea

Flat screens limit how you think. Your brain is spatial. You remember *where*
the sticky note was, you spread papers across a desk, you map out arguments on a
whiteboard. Then we go and cram every thought into a screen behind plain text.
It's the era of spatial computing and we're still designing against our own wiring.

SpatialBoard says nah. Your room is the canvas. You write, sketch, and solve math in
the air with your hands, and ideas just *stay where you put them*, at the size you gave
them, the way your memory actually files stuff. Big thought, big space. No 13-inch glowing slab telling you to scroll.

> ### There's one catch with thinking in space:
> it's **amazing for brainstorming** and **absolutely useless for finding anything a week
> later**. So we bolted a **cloud brain** onto it. The phone catches the chaos, AWS does the
> boring genius work in the background, and suddenly your scattered mess is a **neat little
> library you can pull up from anywhere**.

- **Think in space (iOS):** draw, organize, and solve math in 3D with hand gestures.
  Your handwriting gets reproduced in *your own* style by an on-device engine called Kon.
  Notes anchor to the real world and stay put across sessions.
- **Let the cloud cook (AWS):** stroke batches get clustered into notes, projected to
  SVG, read by a vision model, embedded for semantic search, then auto-titled and sorted.
  Transformation, not just a backup.
- **Find it anywhere (web):** a snappy library with hybrid + semantic search,
  ask-your-notes RAG, folders, sharing, pinning, and a command palette.

Two halves, one product: a spatial way to think, plus a cloud that makes everything you
thought instantly findable.

---

## Architecture

The whole journey, left to right: capture on iOS, enrich on AWS, browse on the web.
Full Mermaid source in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

```
┌──────────────────────┐        ┌───────────────────────────────────────────┐        ┌────────────────────┐
│  iOS (capture)        │       │  AWS · us-east-1                            │        │  Vercel · Next.js   │
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

### The AWS pipeline

The database is the main character. **One Aurora PostgreSQL** handles relational
metadata, JSONB stroke blobs, full-text search, *and* vector search, so there's no
second store bolted on the side just to look fancy.

| Stage | Service | What it does |
| --- | --- | --- |
| Ingest | API Gateway (HTTP API) + **Ingest Lambda** | Takes stroke batches from iOS. **Single-linkage clustering** (0.16 m) groups strokes into notes, in-app folders become categories, and a new cluster within 0.30 m of an old note re-joins it (write near last week's note and it just continues the page). |
| Queue | **SQS** (+ DLQ) | Keeps instant ingest separate from the heavy enrichment work. |
| Enrich | **Process Lambda** | Projects 3D strokes into a smoothed 2D SVG (Catmull-Rom). **Bedrock Nova Pro** reads the page, splits it into its distinct pieces, and labels each with a subject, topic title, and type. **Bedrock Titan v2** does 1024-d embeddings used for both search and topic-matching. See "Smart organization" below. |
| Store | **Aurora Serverless v2 (PostgreSQL) + pgvector** | `notes` carries a `tsvector` (keyword) *and* a `vector(1024)` column (semantic) side by side. Strokes are JSONB. Folders, spaces, and shares are relational. |
| Auth | **Auth Lambda** (JWT, scrypt) | Email/password identity, shared with the web app through a deterministic per-email UUID. |
| Serve | **Vercel / Next.js** via **RDS Data API (HTTP)** | No VPC or connection-pool headaches from serverless functions. |

**Cost flex:** Aurora can scale all the way to zero (min 0 ACU) when nobody's around,
and the Lambdas reach it over the RDS Data API, so the VPC needs **no NAT gateway**.
Idle cost is basically a rounding error. Genuinely, the database scaling to literal $0
and waking back up on its own is when we realized AWS is truly **AWSome**. We don't make
the rules.

Schema: [infra/db/schema.sql](infra/db/schema.sql) · Plan: [docs/AWS_PLAN.md](docs/AWS_PLAN.md) · Deploy: [docs/DEPLOY.md](docs/DEPLOY.md)

### Smart organization (the part that feels like magic)

A spatial brain-dump is messy on purpose, so the pipeline does the tidying:

- **Auto-split by content.** Scribble a to-do list, an equation, and a random phrase
  on the same board and it doesn't become one blob. The model finds each distinct
  piece, figures out which strokes belong to it, and splits them into **separate notes**,
  each with its own handwriting + transcription.
- **Subject folders, topic notes.** Each piece gets a **subject** (the folder, like
  "Physics") and a **topic** (the note, like "Newton's Laws"). Write physics today and
  biology tomorrow and they sort themselves into the right binders. No tagging.
- **Context-aware append.** Here's the good part: write more NLM next week, anywhere in
  your space, and it folds into the *existing* "Newton's Laws" note instead of making a
  duplicate. It only merges when the **subject matches AND** the content is genuinely
  close (cosine distance under a tight bar via pgvector), so EM Waves stays its own note
  even though it's also Physics.
- **Designed per type.** The transcription isn't one flat paragraph. To-dos become
  **tickable checkboxes** (state persists), math renders in an **equation card** with
  real superscripts, code gets a **mono block**, ideas get a **callout**.

### The web companion (Next.js on Vercel)

- **Three-pane workspace:** spaces → categories/folders → notes → detail.
- **Hybrid search:** keyword (`tsvector`) and semantic (`pgvector`) results fused with
  Reciprocal Rank Fusion, all inside one SQL query.
- **Ask your notes:** RAG. Titan embeds your question, pgvector grabs the closest notes,
  Bedrock streams back a cited answer.
- **Handwriting playback:** every note's strokes redraw in reading order like a real pen.
- **Type-aware transcription:** interactive to-do checkboxes, equation cards, code blocks,
  and idea callouts instead of one flat wall of text.
- **Sharing:** hand a note to another account (handwriting, text, or both).
- **The little things:** ⌘K command palette, toasts with undo, pinning, a responsive
  mobile drawer, long-press folder actions, and that 30-day login.

Web code lives in [web/](web/), infra-as-code (AWS CDK) in [infra/](infra/).

---

## Kon, the handwriting engine

Kon copies *your* handwriting and solves the math you scribble mid-air.

During onboarding it grabs your A to Z letterforms, then a segmentation + OCR pipeline
keeps feeding live glyph samples from your AR strokes into your personal style profile.
So when it writes something back, it looks like *you* wrote it, sized to match its
neighbors. For math, Kon zeroes in on the closest equation in front of you (depth
culling), ships an optimized image to Gemini, and drops the answer right next to the
equation in your own hand.

---

## iOS app features

### Spatial canvas
- Notes anchored to real-world coordinates with ARKit WorldAnchors
- Persistent across sessions via SwiftData, plus 3D folder entities to organize in space
- Depth-aware drawing-plane locking so strokes land where you mean them to
- Space-based isolation, so each workspace only shows its own stuff

### Hand gesture system (Vision framework)
- **Pinch** (thumb + index): draw · **Two-hand pinch**: selection rectangle
- **Palm (while selected)**: move strokes/folders in 3D · **Pinch (while selected)**: resize
- **Open palm**: erase (off while selecting) · **Pointing**: open/close folders
- Real-time 2D hand-landmark detection with optimized 3D positioning, pinch hysteresis so
  it doesn't flicker, and depth-aware palm/point raycasting

### Drawing
- Strokes captured as bezier curves, rendered as 3D tube meshes (RealityKit MeshResource),
  stored as world-anchored entities
- Smooth stroke starts, partial erasing with segment splitting, selection outlines, and a
  folder glow when you drag something toward it

### Selection, move, resize, folders
- 2D selection rectangle projected from a two-hand pinch onto scene entities
- Palm-locked move with smoothing, billboard behavior kept for strokes and folders
- Drag-and-drop into folders by proximity, open/close a folder by pointing and holding

### Spaces, style matching, math
- Multiple named spatial workspaces with animated transitions, `spaceID`-scoped loading,
  and swipe-to-delete
- Kon keeps learning your handwriting from your AR strokes, on-device
- Kon math solving with 3D equation targeting and depth culling (see above)

### Performance
- Non-blocking Vision processing on its own queue, throttled gesture-priority hand
  tracking, minimal raycast conversions, LiDAR depth at 15fps, and distance culling

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
├── landing_page/            # Marketing site
└── docs/                    # ARCHITECTURE, AWS_PLAN, DEPLOY, AUTH_SETUP
```

---

## Setup

### Web companion (the AWS deliverable)
```bash
cd web
npm install
cp .env.example .env.local   # add Aurora ARN/secret, AWS region, AUTH_SECRET, etc.
npm run dev
```
[docs/DEPLOY.md](docs/DEPLOY.md) has the full CDK provisioning steps for Aurora + Lambdas
and the exact Vercel environment variables.

### iOS app
1. Open [WhiteBoARd.xcodeproj](WhiteBoARd.xcodeproj) in Xcode 17+
2. Set your development team in Signing & Capabilities
3. Add your Gemini key (for Kon math): `GEMINI_API_KEY` env var, or
   `GeminiService.shared.configure(apiKey:)`
4. Build and run on a real iPhone Pro (LiDAR required, sorry simulator)

---

## Requirements

| Component | Version / Requirement |
| --- | --- |
| iOS | 26.0 or later (real iPhone with LiDAR for full AR) |
| Xcode / Swift | 17.0+ / Swift 6.0 |
| Web | Node 18+, Next.js (App Router) |
| Cloud | AWS account (Aurora Serverless v2, Bedrock, Lambda, SQS, API Gateway) + Vercel |

The iOS app is a Swift Package / Xcode app target meant for real devices. The simulator
handles some logic and UI (`#if targetEnvironment(simulator)` guards), but AR, LiDAR, and
hand-tracking need actual hardware.

## License

MIT License
