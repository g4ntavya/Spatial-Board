'use client';

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { signOut } from 'next-auth/react';

export type Space = { id: string; name: string; color_hex: string };
type Note = {
  id: string;
  title: string | null;
  category: string | null;
  ocr_text: string | null;
  status: string;
  updated_at: string;
  owner?: string | null; // set for shared notes
  pinned?: boolean;
  note_type?: string | null; // rendering type: todo | math | code | idea | text | diagram
};
type Toast = { id: number; msg: string; action?: { label: string; fn: () => void } };
type NoteDetail = Note & { svg: string | null; owned?: boolean };
type Related = { id: string; title: string | null; category: string | null };
type CategoryCount = { category: string; n: number };
type AskResult = { answer: string; sources: { id: string; title: string | null }[] };

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));

export default function Workspace({ spaces, dbError, userEmail }: { spaces: Space[]; dbError: boolean; userEmail: string }) {
  const [activeId, setActiveId] = useState<string | undefined>(spaces[0]?.id);
  const [theme, setTheme] = useState<'light' | 'dark'>('light');
  const [query, setQuery] = useState('');
  const [mode, setMode] = useState<'hybrid' | 'keyword' | 'semantic'>('hybrid');
  const [notes, setNotes] = useState<Note[]>([]);
  const [categories, setCategories] = useState<CategoryCount[]>([]);
  const [activeCategory, setActiveCategory] = useState<string | null>(null);
  const [sharedView, setSharedView] = useState(false);
  const [loading, setLoading] = useState(false);
  const [selected, setSelected] = useState<NoteDetail | null>(null);
  const [related, setRelated] = useState<Related[]>([]);
  const [transcribing, setTranscribing] = useState(false);
  const [detailMenuOpen, setDetailMenuOpen] = useState(false);

  // Layout: collapsible + resizable columns (persisted).
  const [sidebarW, setSidebarW] = useState(248);
  const [listW, setListW] = useState(348);
  const [collapsed, setCollapsed] = useState(false);

  // Dialogs
  const [shareFor, setShareFor] = useState<Note | null>(null);
  const [askOpen, setAskOpen] = useState(false);

  // Folders: user-created empty folders live in localStorage (per space) until a
  // note is moved into one, at which point it becomes a real Aurora category.
  const [customFolders, setCustomFolders] = useState<string[]>([]);
  const [creatingFolder, setCreatingFolder] = useState(false);
  const [newFolderName, setNewFolderName] = useState('');
  const [folderMenu, setFolderMenu] = useState<{ category: string; top: number; left: number } | null>(null);

  const canvasRef = useRef<HTMLDivElement>(null);

  // Toasts, command palette, responsive shell
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [isMobile, setIsMobile] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const pushToast = useCallback((msg: string, action?: { label: string; fn: () => void }) => {
    const id = Date.now() + Math.random();
    setToasts((t) => [...t, { id, msg, action }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), action ? 6000 : 3200);
  }, []);

  // Long-press → folder actions (mobile has no right-click). Hold ~480ms on a
  // folder to open the same menu the context-menu shows on desktop.
  const longPress = useRef<{ timer: ReturnType<typeof setTimeout> | null; fired: boolean }>({ timer: null, fired: false });
  const folderHold = (category: string) => ({
    onTouchStart: (e: React.TouchEvent) => {
      const t = e.touches[0];
      longPress.current.fired = false;
      longPress.current.timer = setTimeout(() => {
        longPress.current.fired = true;
        navigator.vibrate?.(10);
        setFolderMenu({
          category,
          top: clamp(t.clientY, 8, window.innerHeight - 90),
          left: clamp(t.clientX, 8, window.innerWidth - 230),
        });
      }, 480);
    },
    onTouchMove: () => { if (longPress.current.timer) { clearTimeout(longPress.current.timer); longPress.current.timer = null; } },
    onTouchEnd: () => { if (longPress.current.timer) { clearTimeout(longPress.current.timer); longPress.current.timer = null; } },
  });

  // ── Responsive + ⌘K ──
  useEffect(() => {
    const mq = window.matchMedia('(max-width: 760px)');
    const update = () => setIsMobile(mq.matches);
    update();
    mq.addEventListener('change', update);
    return () => mq.removeEventListener('change', update);
  }, []);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); setPaletteOpen((o) => !o); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  // ── Theme ──
  useEffect(() => {
    setTheme((localStorage.getItem('sb-theme') as 'light' | 'dark' | null) ?? (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'));
    const sw = Number(localStorage.getItem('sb-sidebarW')); if (sw) setSidebarW(clamp(sw, 190, 420));
    const lw = Number(localStorage.getItem('sb-listW')); if (lw) setListW(clamp(lw, 280, 560));
    setCollapsed(localStorage.getItem('sb-collapsed') === '1');
  }, []);
  useEffect(() => { document.documentElement.dataset.theme = theme; localStorage.setItem('sb-theme', theme); }, [theme]);
  useEffect(() => { localStorage.setItem('sb-sidebarW', String(sidebarW)); }, [sidebarW]);
  useEffect(() => { localStorage.setItem('sb-listW', String(listW)); }, [listW]);
  useEffect(() => { localStorage.setItem('sb-collapsed', collapsed ? '1' : '0'); }, [collapsed]);

  // ── Custom folders (per space) ──
  useEffect(() => {
    if (!activeId) { setCustomFolders([]); return; }
    try { setCustomFolders(JSON.parse(localStorage.getItem(`sb-folders-${activeId}`) || '[]')); }
    catch { setCustomFolders([]); }
  }, [activeId]);
  useEffect(() => {
    if (activeId) localStorage.setItem(`sb-folders-${activeId}`, JSON.stringify(customFolders));
  }, [customFolders, activeId]);

  // ── Accent theming: the active space's colour drives the whole UI accent ──
  useEffect(() => {
    const sp = spaces.find((s) => s.id === activeId);
    if (sp?.color_hex) document.documentElement.style.setProperty('--accent', sp.color_hex);
  }, [activeId, spaces]);

  // ── Self-drawing ink: draw strokes in reading order (top→bottom, left→right),
  // one after another and fluidly. Longer strokes take proportionally longer, so
  // it reads like a pen actually writing it out, word by word. ──
  useEffect(() => {
    const el = canvasRef.current;
    if (!el || !selected?.svg) return;
    // Inject the SVG ourselves (React doesn't own this subtree) so that later
    // re-renders — related notes loading, pinning, menus — can never re-commit
    // the markup and wipe the in-progress stroke animation.
    el.innerHTML = selected.svg;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const paths = Array.from(el.querySelectorAll('path')) as SVGPathElement[];
    if (!paths.length) return;

    type Info = { p: SVGPathElement; len: number; x: number; cy: number; h: number };
    const info: Info[] = paths.map((p) => {
      let len = 0, x = 0, cy = 0, h = 0;
      try { len = p.getTotalLength(); const b = p.getBBox(); x = b.x; cy = b.y + b.height / 2; h = b.height; } catch { /* ignore */ }
      const ok = len > 0 && isFinite(len);
      if (ok) { p.style.strokeDasharray = String(len); p.style.strokeDashoffset = String(len); } // hide now (no flash)
      return { p, len: ok ? len : 0, x, cy, h };
    });

    // Reading order. Group strokes into lines by vertical *center* (so a tall
    // letter and a short one on the same line stay together), then strictly
    // left→right within each line. Greedy grouping against a running line center
    // avoids the off-by-one a hard bucket grid causes when strokes straddle an
    // edge — that was making the pen jump ahead a letter and then back.
    const all = info.filter((o) => o.len > 0);
    const heights = all.map((o) => o.h).filter((v) => v > 0).sort((a, b) => a - b);
    const band = Math.max((heights[heights.length >> 1] || 20) * 0.6, 1);
    const lines: Info[][] = [];
    let cur: Info[] = [];
    let curCenter = 0;
    for (const o of [...all].sort((a, b) => a.cy - b.cy)) {
      if (cur.length && Math.abs(o.cy - curCenter) > band) { lines.push(cur); cur = []; }
      cur.push(o);
      curCenter = cur.reduce((s, k) => s + k.cy, 0) / cur.length;
    }
    if (cur.length) lines.push(cur);
    const drawable = lines.flatMap((line) => line.sort((a, b) => a.x - b.x));
    const total = drawable.reduce((s, o) => s + o.len, 0) || 1;
    const budget = Math.min(5500, Math.max(2200, drawable.length * 260)); // ms — scales w/ #strokes
    const speed = total / budget; // svg-units per ms (constant pen speed)
    let cursor = 0;
    const anims: Animation[] = [];
    for (const o of drawable) {
      const dur = Math.min(1100, Math.max(160, o.len / speed));
      const a = o.p.animate(
        [{ strokeDashoffset: o.len }, { strokeDashoffset: 0 }],
        { duration: dur, delay: cursor, easing: 'cubic-bezier(.22, .61, .36, 1)', fill: 'forwards' },
      );
      a.onfinish = () => { o.p.style.strokeDashoffset = '0'; };
      anims.push(a);
      cursor += dur * 0.9; // 10% overlap → one stroke flows into the next
    }
    return () => { anims.forEach((a) => { try { a.cancel(); } catch { /* ignore */ } }); };
  }, [selected?.id, selected?.svg]);

  // ── Data loading ──
  const loadNotes = useCallback(async () => {
    if (!activeId) return;
    setLoading(true);
    try {
      const params = new URLSearchParams({ space: activeId, mode });
      if (query.trim()) params.set('q', query.trim());
      const res = await fetch(`/api/notes?${params}`, { cache: 'no-store' });
      setNotes(res.ok ? await res.json() : []);
    } finally { setLoading(false); }
  }, [activeId, query, mode]);

  const loadShared = useCallback(async () => {
    setLoading(true);
    try {
      const res = await fetch('/api/shared', { cache: 'no-store' });
      setNotes(res.ok ? await res.json() : []);
    } finally { setLoading(false); }
  }, []);

  const loadCategories = useCallback(async () => {
    if (!activeId) return;
    const res = await fetch(`/api/categories?space=${activeId}`, { cache: 'no-store' });
    setCategories(res.ok ? await res.json() : []);
  }, [activeId]);

  useEffect(() => {
    if (sharedView) { loadShared(); return; }
    const t = setTimeout(loadNotes, query ? 300 : 0);
    return () => clearTimeout(t);
  }, [sharedView, loadNotes, loadShared, query]);
  useEffect(() => { if (!sharedView) loadCategories(); }, [loadCategories, notes.length, sharedView]);

  const openNote = async (id: string) => {
    setRelated([]); setDetailMenuOpen(false);
    const res = await fetch(`/api/note?id=${id}`, { cache: 'no-store' });
    if (res.ok) setSelected(await res.json());
    fetch(`/api/related?id=${id}`, { cache: 'no-store' }).then(async (r) => r.ok && setRelated(await r.json()));
  };

  const deleteNote = async (id: string) => {
    setNotes((prev) => prev.filter((n) => n.id !== id));
    if (selected?.id === id) { setSelected(null); setDetailMenuOpen(false); }
    await fetch(`/api/note?id=${id}`, { method: 'DELETE' });
    loadCategories();
    pushToast('Note deleted');
  };

  const moveNote = async (id: string, category: string) => {
    const prev = notes.find((n) => n.id === id)?.category ?? null;
    setNotes((p) => p.map((n) => (n.id === id ? { ...n, category } : n)));
    if (selected?.id === id) setSelected({ ...selected, category });
    await fetch('/api/note', { method: 'PATCH', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ id, category }) });
    loadCategories();
    pushToast(`Moved to ${category}`, prev ? { label: 'Undo', fn: () => moveNote(id, prev) } : undefined);
  };

  const togglePin = async (id: string, pinned: boolean) => {
    setNotes((p) => p.map((n) => (n.id === id ? { ...n, pinned } : n)));
    if (selected?.id === id) setSelected({ ...selected, pinned });
    await fetch('/api/note', { method: 'PATCH', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ id, pinned }) });
    pushToast(pinned ? 'Pinned' : 'Unpinned');
  };

  // Merge Aurora-derived categories with not-yet-used custom folders (n = 0).
  const folderList = useMemo<CategoryCount[]>(() => {
    const seen = new Set(categories.map((c) => c.category));
    const extras = customFolders.filter((f) => !seen.has(f)).map((f) => ({ category: f, n: 0 }));
    return [...categories, ...extras];
  }, [categories, customFolders]);

  const addFolder = () => {
    const name = newFolderName.trim();
    setNewFolderName('');
    setCreatingFolder(false);
    if (!name) return;
    if (!folderList.some((c) => c.category === name)) setCustomFolders((p) => [...p, name]);
    setSharedView(false);
    setActiveCategory(name);
  };

  const deleteFolder = async (category: string) => {
    if (!activeId) return;
    const n = categories.find((c) => c.category === category)?.n ?? 0;
    if (n > 0 && !window.confirm(`Delete “${category}” and its ${n} note${n === 1 ? '' : 's'}? This can’t be undone.`)) return;
    setCustomFolders((p) => p.filter((f) => f !== category));
    if (activeCategory === category) setActiveCategory(null);
    if (n > 0) {
      setNotes((prev) => prev.filter((nt) => (nt.category || 'Uncategorized') !== category));
      if (selected && (selected.category || 'Uncategorized') === category) setSelected(null);
      await fetch(`/api/categories?space=${activeId}&category=${encodeURIComponent(category)}`, { method: 'DELETE' });
      loadCategories();
    }
  };

  const transcribe = async () => {
    if (!selected) return;
    setTranscribing(true);
    await fetch('/api/transcribe', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ id: selected.id }) });
    const id = selected.id;
    for (let i = 0; i < 30; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      const res = await fetch(`/api/note?id=${id}`, { cache: 'no-store' });
      if (!res.ok) break;
      const n: NoteDetail = await res.json();
      if (n.status === 'processed') { setSelected(n); loadNotes(); break; }
    }
    setTranscribing(false);
  };

  // To-do notes store their tasks as a markdown checklist in ocr_text; toggling a
  // box rewrites that line and persists it.
  const toggleCheck = (lineIdx: number) => {
    if (!selected || selected.owned === false) return;
    const lines = (selected.ocr_text ?? '').split('\n');
    const m = lines[lineIdx]?.match(/^(\s*-\s*\[)( |x|X)(\].*)$/);
    if (!m) return;
    lines[lineIdx] = `${m[1]}${m[2] === ' ' ? 'x' : ' '}${m[3]}`;
    const next = lines.join('\n');
    setSelected((p) => (p ? { ...p, ocr_text: next } : p));
    fetch('/api/note', { method: 'PATCH', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ id: selected.id, ocr_text: next }) });
  };

  const goSpace = (id: string) => { setSharedView(false); setActiveId(id); setSelected(null); setActiveCategory(null); setSidebarOpen(false); };

  const visible = useMemo(
    () => (activeCategory && !sharedView ? notes.filter((n) => (n.category || 'Uncategorized') === activeCategory) : notes),
    [notes, activeCategory, sharedView],
  );
  const pinnedNotes = useMemo(() => (sharedView ? [] : visible.filter((n) => n.pinned)), [visible, sharedView]);
  const grouped = useMemo(() => {
    if (query || activeCategory || sharedView) return null;
    const map = new Map<string, Note[]>();
    for (const n of visible) { if (n.pinned) continue; const c = n.category || 'Uncategorized'; if (!map.has(c)) map.set(c, []); map.get(c)!.push(n); }
    return [...map.entries()];
  }, [visible, query, activeCategory, sharedView]);

  if (dbError) {
    return (
      <div className="empty-full">
        <h1>Can’t reach the library</h1>
        <p>The web app couldn’t connect to Aurora. Check the AWS env vars in your Vercel project.</p>
      </div>
    );
  }

  const renderCard = (n: Note) => (
    <NoteRow
      key={n.id}
      note={n}
      active={selected?.id === n.id}
      readOnly={sharedView}
      categories={folderList}
      query={query}
      onOpen={() => openNote(n.id)}
      onDelete={() => deleteNote(n.id)}
      onMove={(c) => moveNote(n.id, c)}
      onShare={() => setShareFor(n)}
      onPin={() => togglePin(n.id, !n.pinned)}
    />
  );

  return (
    <div
      className={`app ${collapsed ? 'is-collapsed' : ''} ${isMobile ? 'is-mobile' : ''} ${selected ? 'has-selection' : ''} ${sidebarOpen ? 'drawer-open' : ''}`}
      style={isMobile ? undefined : { gridTemplateColumns: `${collapsed ? 0 : sidebarW}px ${listW}px 1fr` }}
    >
      {isMobile && (
        <div className="mobile-bar">
          {selected
            ? <button className="icon-btn" onClick={() => setSelected(null)} aria-label="Back"><BackIcon /></button>
            : <button className="icon-btn" onClick={() => setSidebarOpen(true)} aria-label="Menu"><MenuIcon /></button>}
          <span className="brand">SpatialBoard</span>
          <button className="icon-btn" onClick={() => setPaletteOpen(true)} aria-label="Search"><SearchIcon /></button>
        </div>
      )}
      {isMobile && sidebarOpen && <div className="drawer-backdrop" onClick={() => setSidebarOpen(false)} />}
      {collapsed && !isMobile && (
        <button className="expand-btn" onClick={() => setCollapsed(false)} aria-label="Show sidebar"><ExpandIcon /></button>
      )}
      {/* Sidebar */}
      <aside className={`sidebar ${isMobile ? 'is-drawer' : ''}`}>
        <div className="side-top">
          <span className="brand">SpatialBoard</span>
          <div className="side-top-actions">
            <button className="icon-btn" onClick={() => setTheme(theme === 'light' ? 'dark' : 'light')} aria-label="Toggle theme">
              {theme === 'light' ? <MoonIcon /> : <SunIcon />}
            </button>
            <button className="icon-btn" onClick={() => setCollapsed(true)} aria-label="Collapse sidebar"><CollapseIcon /></button>
          </div>
        </div>

        <button className="ask-launch" onClick={() => setAskOpen(true)}><SparkIcon /> Ask your notes</button>

        {spaces.map((s) => (
          <button key={s.id} className={`space-row ${!sharedView && s.id === activeId ? 'active' : ''}`} onClick={() => goSpace(s.id)}>
            <span className="dot" style={{ background: s.color_hex || '#8E8E93' }} />
            {s.name}
          </button>
        ))}

        <div className="folders-label">
          <span>Folders</span>
          <button className="folder-add" onClick={() => setCreatingFolder(true)} aria-label="New folder" title="New folder"><PlusIcon /></button>
        </div>
        <button className={`folder-row ${!sharedView && activeCategory === null ? 'active' : ''}`} onClick={() => { setSharedView(false); setActiveCategory(null); setSidebarOpen(false); }}>
          <FolderIcon /> <span>All notes</span><span className="folder-count">{sharedView ? '' : notes.length}</span>
        </button>
        {creatingFolder && (
          <div className="folder-new">
            <FolderIcon />
            <input
              autoFocus
              value={newFolderName}
              placeholder="Folder name"
              onChange={(e) => setNewFolderName(e.target.value)}
              onBlur={addFolder}
              onKeyDown={(e) => {
                if (e.key === 'Enter') addFolder();
                if (e.key === 'Escape') { setNewFolderName(''); setCreatingFolder(false); }
              }}
            />
          </div>
        )}
        {folderList.map((c) => (
          <button
            key={c.category}
            className={`folder-row ${!sharedView && activeCategory === c.category ? 'active' : ''}`}
            onClick={() => { if (longPress.current.fired) { longPress.current.fired = false; return; } setSharedView(false); setActiveCategory(c.category); setSidebarOpen(false); }}
            onContextMenu={(e) => { e.preventDefault(); setFolderMenu({ category: c.category, top: clamp(e.clientY, 8, window.innerHeight - 90), left: clamp(e.clientX, 8, window.innerWidth - 230) }); }}
            {...folderHold(c.category)}
          >
            <FolderIcon /> <span>{c.category}</span><span className="folder-count">{c.n || ''}</span>
          </button>
        ))}

        <div className="folders-label">Shared</div>
        <button className={`folder-row ${sharedView ? 'active' : ''}`} onClick={() => { setSharedView(true); setSelected(null); setActiveCategory(null); setSidebarOpen(false); }}>
          <ShareIcon /> <span>Shared with me</span>
        </button>

        <div className="account">
          <span className="account-email" title={userEmail}>{userEmail}</span>
          <button className="account-signout" onClick={() => signOut()}>Sign out</button>
        </div>
        <Resizer onDelta={(dx) => setSidebarW((w) => clamp(w + dx, 190, 420))} />
      </aside>

      {/* List */}
      <section className="list">
        <div className="search">
          <input placeholder={sharedView ? 'Search shared…' : 'Search notes…'} value={query} onChange={(e) => setQuery(e.target.value)} disabled={sharedView} />
          {!sharedView && (
            <div className="modes">
              <button className={mode === 'hybrid' ? 'on' : ''} onClick={() => setMode('hybrid')} title="Keyword + semantic, fused (RRF)">Hybrid</button>
              <button className={mode === 'keyword' ? 'on' : ''} onClick={() => setMode('keyword')}>Keyword</button>
              <button className={mode === 'semantic' ? 'on' : ''} onClick={() => setMode('semantic')}>Semantic</button>
            </div>
          )}
        </div>

        <div className="notes">
          {loading && (
            <div className="skeletons">{Array.from({ length: 5 }).map((_, i) => <div key={i} className="skel-card" />)}</div>
          )}
          {!loading && visible.length === 0 && (
            <div className="hint">{sharedView
              ? 'Nothing shared with you yet — ask a friend to share a note.'
              : query
                ? 'No matches. Try another word, or switch to Semantic.'
                : 'No notes yet. Draw in the app, then exit to sync — they show up here.'}</div>
          )}
          {!loading && pinnedNotes.length > 0 && (
            <div className="note-group">
              <div className="group-head"><span className="pin-head"><PinFillIcon /> Pinned</span><span>{pinnedNotes.length}</span></div>
              {pinnedNotes.map(renderCard)}
            </div>
          )}
          {!loading && grouped
            ? grouped.map(([cat, items]) => (
                <div key={cat} className="note-group">
                  <div className="group-head">{cat}<span>{items.length}</span></div>
                  {items.map(renderCard)}
                </div>
              ))
            : !loading && visible.filter((n) => !(pinnedNotes.length > 0 && n.pinned)).map(renderCard)}
        </div>
        <Resizer onDelta={(dx) => setListW((w) => clamp(w + dx, 280, 560))} />
      </section>

      {/* Detail */}
      <main className="detail">
        {selected ? (
          <article className="detail-inner">
            <header className="detail-head">
              <div className="detail-head-text">
                <h1>{selected.title || 'Untitled note'}</h1>
                <div className="detail-meta">
                  {selected.category && <span className="tag">{selected.category}</span>}
                  <span className="date">{formatDate(selected.updated_at)}</span>
                  {selected.owned === false && selected.owner && <span className="shared-by">shared by {selected.owner}</span>}
                </div>
              </div>
              {selected.owned !== false && (
                <div className="kebab-wrap">
                  <button className="kebab-btn" onClick={() => setDetailMenuOpen((o) => !o)} aria-label="Note actions"><KebabIcon /></button>
                  {detailMenuOpen && (
                    <>
                      <div className="menu-backdrop" onClick={() => setDetailMenuOpen(false)} />
                      <div className="kebab-menu">
                        <button className="menu-item" onClick={() => { setDetailMenuOpen(false); togglePin(selected.id, !selected.pinned); }}><PinIcon /> {selected.pinned ? 'Unpin' : 'Pin'}</button>
                        <button className="menu-item" onClick={() => { setDetailMenuOpen(false); setShareFor(selected); }}><ShareIcon /> Share</button>
                        <button className="menu-item danger" onClick={() => deleteNote(selected.id)}><TrashIcon /> Delete note</button>
                      </div>
                    </>
                  )}
                </div>
              )}
            </header>

            {selected.svg ? (
              <div className="canvas" ref={canvasRef} />
            ) : (
              <div className="canvas placeholder">{selected.status === 'pending' ? 'Processing…' : 'Handwriting not shared'}</div>
            )}

            {(selected.owned !== false || selected.ocr_text) && (
              <section className="transcript">
                <div className="transcript-head">
                  <span className="transcript-label">Transcription</span>
                  {selected.owned !== false && (
                    <button className="convert-btn" onClick={transcribe} disabled={transcribing}>
                      {transcribing ? 'Reading…' : selected.ocr_text?.trim() ? 'Re-transcribe' : 'Convert to text'}
                    </button>
                  )}
                </div>
                {selected.ocr_text?.trim() ? (
                  <Transcript text={selected.ocr_text} noteType={selected.note_type} readOnly={selected.owned === false} onToggle={toggleCheck} />
                ) : (
                  <p className="muted">{transcribing ? 'Reading your handwriting…' : 'Not transcribed yet — convert your handwriting to clean text.'}</p>
                )}
              </section>
            )}

            {related.length > 0 && (
              <section className="related">
                <div className="transcript-label">Related notes</div>
                <div className="related-row">
                  {related.map((r) => (
                    <button key={r.id} className="related-card" onClick={() => openNote(r.id)}>
                      <span className="related-title">{r.title || 'Untitled'}</span>
                      {r.category && <span className="tag">{r.category}</span>}
                    </button>
                  ))}
                </div>
              </section>
            )}
          </article>
        ) : (
          <div className="empty">Select a note</div>
        )}
      </main>

      {folderMenu && (
        <>
          <div className="menu-backdrop" onClick={() => setFolderMenu(null)} onContextMenu={(e) => { e.preventDefault(); setFolderMenu(null); }} />
          <div className="kebab-popover" style={{ top: folderMenu.top, left: folderMenu.left }} onClick={(e) => e.stopPropagation()}>
            <div className="menu-label">{folderMenu.category}</div>
            <button className="menu-item danger" onClick={() => { const c = folderMenu.category; setFolderMenu(null); deleteFolder(c); }}>
              <TrashIcon /> Delete folder &amp; notes
            </button>
          </div>
        </>
      )}

      {shareFor && <ShareDialog note={shareFor} onClose={() => setShareFor(null)} onToast={pushToast} />}
      {askOpen && <AskDialog onClose={() => setAskOpen(false)} onOpenNote={(id) => { setAskOpen(false); openNote(id); }} />}

      {paletteOpen && (
        <CommandPalette
          notes={notes}
          spaces={spaces}
          folders={folderList}
          onClose={() => setPaletteOpen(false)}
          onOpenNote={(id) => { setPaletteOpen(false); openNote(id); }}
          onGoSpace={(id) => { setPaletteOpen(false); goSpace(id); }}
          onOpenFolder={(c) => { setPaletteOpen(false); setSharedView(false); setActiveCategory(c); }}
          onAsk={() => { setPaletteOpen(false); setAskOpen(true); }}
          onNewFolder={() => { setPaletteOpen(false); setCreatingFolder(true); }}
          onToggleTheme={() => setTheme(theme === 'light' ? 'dark' : 'light')}
          onAllNotes={() => { setPaletteOpen(false); setSharedView(false); setActiveCategory(null); }}
          onShared={() => { setPaletteOpen(false); setSharedView(true); setSelected(null); setActiveCategory(null); }}
        />
      )}

      <div className="toaster">
        {toasts.map((t) => (
          <div key={t.id} className="toast">
            <span>{t.msg}</span>
            {t.action && (
              <button className="toast-action" onClick={() => { t.action!.fn(); setToasts((x) => x.filter((y) => y.id !== t.id)); }}>{t.action.label}</button>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}

// ── Resizer handle ──
function Resizer({ onDelta }: { onDelta: (dx: number) => void }) {
  const startX = useRef(0);
  const dragging = useRef(false);
  return (
    <div
      className="resizer"
      onPointerDown={(e) => { startX.current = e.clientX; dragging.current = true; e.currentTarget.setPointerCapture(e.pointerId); }}
      onPointerMove={(e) => { if (!dragging.current) return; const dx = e.clientX - startX.current; startX.current = e.clientX; onDelta(dx); }}
      onPointerUp={(e) => { dragging.current = false; e.currentTarget.releasePointerCapture(e.pointerId); }}
    />
  );
}

// ── Share dialog ──
function ShareDialog({ note, onClose, onToast }: { note: Note; onClose: () => void; onToast: (m: string) => void }) {
  const [email, setEmail] = useState('');
  const [mode, setMode] = useState<'both' | 'strokes' | 'text'>('both');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const submit = async () => {
    setBusy(true); setMsg(null);
    const res = await fetch('/api/share', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ noteId: note.id, email, mode }) });
    setBusy(false);
    if (res.ok) { onToast(`Shared with ${email}`); onClose(); }
    else setMsg((await res.json().catch(() => ({})))?.error || 'Failed');
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <h3>Share “{note.title || 'Untitled note'}”</h3>
        <input className="modal-input" type="email" placeholder="Recipient email" value={email} onChange={(e) => setEmail(e.target.value)} autoFocus />
        <div className="seg">
          {(['both', 'strokes', 'text'] as const).map((m) => (
            <button key={m} className={mode === m ? 'on' : ''} onClick={() => setMode(m)}>
              {m === 'both' ? 'Handwriting + text' : m === 'strokes' ? 'Handwriting only' : 'Text only'}
            </button>
          ))}
        </div>
        {msg && <div className="modal-msg">{msg}</div>}
        <div className="modal-actions">
          <button className="btn-ghost" onClick={onClose}>Cancel</button>
          <button className="btn-primary" onClick={submit} disabled={busy || !email}>{busy ? 'Sharing…' : 'Share'}</button>
        </div>
      </div>
    </div>
  );
}

// ── Ask-your-notes (RAG) dialog — streamed answer ──
function AskDialog({ onClose, onOpenNote }: { onClose: () => void; onOpenNote: (id: string) => void }) {
  const [q, setQ] = useState('');
  const [busy, setBusy] = useState(false);
  const [answer, setAnswer] = useState('');
  const [sources, setSources] = useState<AskResult['sources']>([]);
  const [asked, setAsked] = useState(false);

  const ask = async () => {
    if (!q.trim() || busy) return;
    setBusy(true); setAnswer(''); setSources([]); setAsked(true);
    try {
      const r = await fetch('/api/ask', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ question: q }) });
      try {
        const b = r.headers.get('x-sources');
        if (b) setSources(JSON.parse(atob(b)));
      } catch { /* ignore */ }
      if (!r.body) { setAnswer('Something went wrong.'); return; }
      const reader = r.body.getReader();
      const dec = new TextDecoder();
      let acc = '';
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        acc += dec.decode(value, { stream: true });
        setAnswer(acc);
      }
    } catch {
      setAnswer('Something went wrong.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal modal-ask" onClick={(e) => e.stopPropagation()}>
        <h3><SparkIcon /> Ask your notes</h3>
        <p className="modal-sub">Answered by Bedrock over your notes (Titan retrieval + Nova).</p>
        <div className="ask-row">
          <input className="modal-input" placeholder="e.g. what did I need from the store?" value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && ask()} autoFocus />
          <button className="btn-primary" onClick={ask} disabled={busy || !q.trim()}>{busy ? '…' : 'Ask'}</button>
        </div>
        {asked && (
          <div className="ask-answer">
            <p>{answer}{busy && <span className="ask-caret" />}</p>
            {sources.length > 0 && (
              <div className="ask-sources">
                {sources.map((s) => (
                  <button key={s.id} className="related-card" onClick={() => onOpenNote(s.id)}>
                    <span className="related-title">{s.title || 'Untitled'}</span>
                  </button>
                ))}
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

function formatDate(iso: string) {
  const d = new Date(iso.replace(' ', 'T') + 'Z');
  if (isNaN(d.getTime())) return '';
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

const MoonIcon = () => (<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z" /></svg>);
const SunIcon = () => (<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M19 5l-1.5 1.5M6.5 17.5L5 19" /></svg>);
const FolderIcon = () => (<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" /></svg>);
const KebabIcon = () => (<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="5" r="1.6" /><circle cx="12" cy="12" r="1.6" /><circle cx="12" cy="19" r="1.6" /></svg>);
const TrashIcon = () => (<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14" /></svg>);
const ShareIcon = () => (<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><circle cx="18" cy="5" r="2.5" /><circle cx="6" cy="12" r="2.5" /><circle cx="18" cy="19" r="2.5" /><path d="M8.2 10.8 15.8 6.2M8.2 13.2l7.6 4.6" /></svg>);
const SparkIcon = () => (<svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor"><path d="M12 2l1.6 5.4L19 9l-5.4 1.6L12 16l-1.6-5.4L5 9l5.4-1.6z" /></svg>);
const CollapseIcon = () => (<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M15 6l-6 6 6 6" /></svg>);
const ExpandIcon = () => (<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M9 4v16" /></svg>);
const PlusIcon = () => (<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"><path d="M12 5v14M5 12h14" /></svg>);
const MenuIcon = () => (<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M3 6h18M3 12h18M3 18h18" /></svg>);
const BackIcon = () => (<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M15 6l-6 6 6 6" /></svg>);
const SearchIcon = () => (<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="11" cy="11" r="7" /><path d="M21 21l-4.3-4.3" /></svg>);
const PinIcon = () => (<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"><path d="M12 17v5M9 3h6l-1 6 3 3H7l3-3-1-6z" /></svg>);
const CheckIcon = () => (<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"><path d="M20 6 9 17l-5-5" /></svg>);

// Superscript-aware math line: turns `6^2` / `x^(n+1)` into real <sup> nodes.
function mathNodes(line: string) {
  const out: React.ReactNode[] = [];
  const re = /\^(\{[^}]+\}|\([^)]+\)|[0-9a-zA-Z]+)/g;
  let last = 0, k = 0, m: RegExpExecArray | null;
  while ((m = re.exec(line))) {
    if (m.index > last) out.push(line.slice(last, m.index));
    out.push(<sup key={k++}>{m[1].replace(/[(){}]/g, '')}</sup>);
    last = m.index + m[0].length;
  }
  if (last < line.length) out.push(line.slice(last));
  return out;
}

// Renders the transcription with a designed treatment per note type: to-do →
// interactive checkboxes, math → equation card, code → code block, idea →
// callout, everything else → clean prose.
function Transcript({ text, noteType, readOnly, onToggle }: {
  text: string; noteType?: string | null; readOnly?: boolean; onToggle: (lineIdx: number) => void;
}) {
  const lines = text.split('\n');

  if (noteType === 'todo' || /(^|\n)\s*-\s*\[( |x|X)\]/.test(text)) {
    return (
      <ul className="todo-list">
        {lines.map((line, i) => {
          const m = line.match(/^\s*-\s*\[( |x|X)\]\s*(.*)$/);
          if (!m) return line.trim() ? <p key={i} className="todo-aside">{line}</p> : null;
          const checked = m[1] !== ' ';
          return (
            <li key={i} className={`todo-item ${checked ? 'done' : ''}`}>
              <button type="button" className="todo-check" role="checkbox" aria-checked={checked} onClick={() => onToggle(i)} disabled={readOnly}>
                {checked && <CheckIcon />}
              </button>
              <span>{m[2]}</span>
            </li>
          );
        })}
      </ul>
    );
  }

  if (noteType === 'math') {
    return (
      <div className="eq-block">
        {lines.filter((l) => l.trim()).map((l, i) => <div key={i} className="eq-line">{mathNodes(l)}</div>)}
      </div>
    );
  }

  if (noteType === 'code') {
    return <pre className="code-block"><code>{text}</code></pre>;
  }

  if (noteType === 'idea') {
    return (
      <div className="idea-callout">
        {lines.filter((l) => l.trim()).map((l, i) => <p key={i}>{l}</p>)}
      </div>
    );
  }

  return <p>{text}</p>;
}
const PinFillIcon = () => (<svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><path d="M9 3h6l-1 6 3 3H7l3-3-1-6z" /><rect x="11" y="15" width="2" height="6" rx="1" /></svg>);

// ── ⌘K command palette ──
type Cmd = { id: string; label: string; hint?: string; run: () => void };
function CommandPalette({ notes, spaces, folders, onClose, onOpenNote, onGoSpace, onOpenFolder, onAsk, onNewFolder, onToggleTheme, onAllNotes, onShared }: {
  notes: Note[]; spaces: Space[]; folders: CategoryCount[];
  onClose: () => void; onOpenNote: (id: string) => void; onGoSpace: (id: string) => void; onOpenFolder: (c: string) => void;
  onAsk: () => void; onNewFolder: () => void; onToggleTheme: () => void; onAllNotes: () => void; onShared: () => void;
}) {
  const [q, setQ] = useState('');
  const [sel, setSel] = useState(0);

  const cmds = useMemo<Cmd[]>(() => {
    const base: Cmd[] = [
      { id: 'ask', label: 'Ask your notes', hint: 'AI', run: onAsk },
      { id: 'all', label: 'All notes', hint: 'Go', run: onAllNotes },
      { id: 'shared', label: 'Shared with me', hint: 'Go', run: onShared },
      { id: 'newfolder', label: 'New folder', hint: 'Create', run: onNewFolder },
      { id: 'theme', label: 'Toggle theme', hint: 'View', run: onToggleTheme },
      ...spaces.map((s) => ({ id: `sp-${s.id}`, label: `Space: ${s.name}`, hint: 'Go', run: () => onGoSpace(s.id) })),
      ...folders.map((f) => ({ id: `fo-${f.category}`, label: `Folder: ${f.category}`, hint: 'Go', run: () => onOpenFolder(f.category) })),
      ...notes.slice(0, 60).map((n) => ({ id: `nt-${n.id}`, label: n.title || 'Untitled note', hint: 'Note', run: () => onOpenNote(n.id) })),
    ];
    const s = q.trim().toLowerCase();
    if (!s) return base.slice(0, 12);
    return base.filter((c) => c.label.toLowerCase().includes(s)).slice(0, 30);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q, notes, spaces, folders]);

  useEffect(() => { setSel(0); }, [q]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
      else if (e.key === 'ArrowDown') { e.preventDefault(); setSel((i) => Math.min(i + 1, cmds.length - 1)); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); setSel((i) => Math.max(i - 1, 0)); }
      else if (e.key === 'Enter') { e.preventDefault(); cmds[sel]?.run(); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [cmds, sel, onClose]);

  return (
    <div className="modal-backdrop palette-backdrop" onClick={onClose}>
      <div className="palette" onClick={(e) => e.stopPropagation()}>
        <input className="palette-input" placeholder="Search notes, folders, actions…" value={q} onChange={(e) => setQ(e.target.value)} autoFocus />
        <div className="palette-list">
          {cmds.length === 0 && <div className="palette-empty">No matches</div>}
          {cmds.map((c, i) => (
            <button key={c.id} className={`palette-item ${i === sel ? 'sel' : ''}`} onMouseEnter={() => setSel(i)} onClick={() => c.run()}>
              <span className="palette-label">{c.label}</span>
              {c.hint && <span className="palette-hint">{c.hint}</span>}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

// Wrap query terms in <mark> so matches stand out in titles + snippets.
function highlight(text: string, q?: string) {
  const s = (q ?? '').trim();
  if (!s || !text) return text;
  const terms = s.split(/\s+/).filter((t) => t.length > 1).map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  if (!terms.length) return text;
  const splitRe = new RegExp(`(${terms.join('|')})`, 'gi');
  const matchRe = new RegExp(`^(?:${terms.join('|')})$`, 'i');
  return text.split(splitRe).map((part, i) => (matchRe.test(part) ? <mark key={i} className="hl">{part}</mark> : part));
}

// A note card with an Apple-style ⋯ menu (Move / Share / Delete). The menu is a
// fixed-position popover anchored to the button, so it's never clipped.
function NoteRow({ note, active, readOnly, categories, query, onOpen, onDelete, onMove, onShare, onPin }: {
  note: Note; active: boolean; readOnly?: boolean; categories: CategoryCount[]; query?: string;
  onOpen: () => void; onDelete: () => void; onMove: (category: string) => void; onShare: () => void; onPin: () => void;
}) {
  const [menuOpen, setMenuOpen] = useState(false);
  const [pos, setPos] = useState({ top: 0, left: 0 });
  const btnRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);

  const snippet = note.ocr_text?.trim()
    || (note.owner ? `from ${note.owner}` : note.status === 'partial' ? 'Handwriting saved · tap Convert to text' : note.status === 'pending' ? 'Processing…' : 'No text yet');

  useEffect(() => {
    if (!menuOpen) return;
    const close = (e: Event) => {
      if (menuRef.current?.contains(e.target as Node) || btnRef.current?.contains(e.target as Node)) return;
      setMenuOpen(false);
    };
    document.addEventListener('mousedown', close);
    window.addEventListener('scroll', () => setMenuOpen(false), true);
    return () => { document.removeEventListener('mousedown', close); };
  }, [menuOpen]);

  const toggleMenu = (e: React.MouseEvent) => {
    e.stopPropagation();
    const r = btnRef.current!.getBoundingClientRect();
    const W = 210;
    setPos({ top: r.bottom + 6, left: clamp(r.right - W, 8, window.innerWidth - W - 8) });
    setMenuOpen((o) => !o);
  };

  const moveTargets = categories.filter((c) => c.category !== (note.category || 'Uncategorized'));

  return (
    <div className="note-row">
      <div className={`note-card ${active ? 'active' : ''}`} onClick={onOpen}>
        <div className="note-title">{highlight(note.title || 'Untitled note', query)}</div>
        <div className="note-snippet">{highlight(snippet, query)}</div>
        <div className="note-meta">
          {note.pinned && <span className="note-pin" title="Pinned"><PinFillIcon /></span>}
          {note.category && <span className="tag">{note.category}</span>}
          <span className="date">{formatDate(note.updated_at)}</span>
        </div>
        {!readOnly && (
          <button ref={btnRef} className="note-more" onClick={toggleMenu} aria-label="Note actions"><KebabIcon /></button>
        )}
      </div>
      {menuOpen && (
        <div ref={menuRef} className="kebab-popover" style={{ top: pos.top, left: pos.left }} onClick={(e) => e.stopPropagation()}>
          {moveTargets.length > 0 && <div className="menu-label">Move to</div>}
          {moveTargets.map((c) => (
            <button key={c.category} className="menu-item" onClick={() => { setMenuOpen(false); onMove(c.category); }}><FolderIcon /> {c.category}</button>
          ))}
          {moveTargets.length > 0 && <div className="menu-sep" />}
          <button className="menu-item" onClick={() => { setMenuOpen(false); onPin(); }}><PinIcon /> {note.pinned ? 'Unpin' : 'Pin'}</button>
          <button className="menu-item" onClick={() => { setMenuOpen(false); onShare(); }}><ShareIcon /> Share</button>
          <button className="menu-item danger" onClick={() => { setMenuOpen(false); onDelete(); }}><TrashIcon /> Delete</button>
        </div>
      )}
    </div>
  );
}
