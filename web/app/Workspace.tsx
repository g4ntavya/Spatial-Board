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
};
type NoteDetail = Note & { svg: string | null; owned?: boolean };
type Related = { id: string; title: string | null; category: string | null };
type CategoryCount = { category: string; n: number };
type AskResult = { answer: string; sources: { id: string; title: string | null }[] };

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));

export default function Workspace({ spaces, dbError, userEmail }: { spaces: Space[]; dbError: boolean; userEmail: string }) {
  const [activeId, setActiveId] = useState<string | undefined>(spaces[0]?.id);
  const [theme, setTheme] = useState<'light' | 'dark'>('light');
  const [query, setQuery] = useState('');
  const [mode, setMode] = useState<'keyword' | 'semantic'>('keyword');
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
  };

  const moveNote = async (id: string, category: string) => {
    setNotes((prev) => prev.map((n) => (n.id === id ? { ...n, category } : n)));
    if (selected?.id === id) setSelected({ ...selected, category });
    await fetch('/api/note', { method: 'PATCH', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ id, category }) });
    loadCategories();
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

  const goSpace = (id: string) => { setSharedView(false); setActiveId(id); setSelected(null); setActiveCategory(null); };

  const visible = useMemo(
    () => (activeCategory && !sharedView ? notes.filter((n) => (n.category || 'Uncategorized') === activeCategory) : notes),
    [notes, activeCategory, sharedView],
  );
  const grouped = useMemo(() => {
    if (query || activeCategory || sharedView) return null;
    const map = new Map<string, Note[]>();
    for (const n of visible) { const c = n.category || 'Uncategorized'; if (!map.has(c)) map.set(c, []); map.get(c)!.push(n); }
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
      categories={categories}
      onOpen={() => openNote(n.id)}
      onDelete={() => deleteNote(n.id)}
      onMove={(c) => moveNote(n.id, c)}
      onShare={() => setShareFor(n)}
    />
  );

  return (
    <div className={`app ${collapsed ? 'is-collapsed' : ''}`} style={{ gridTemplateColumns: `${collapsed ? 0 : sidebarW}px ${listW}px 1fr` }}>
      {collapsed && (
        <button className="expand-btn" onClick={() => setCollapsed(false)} aria-label="Show sidebar"><ExpandIcon /></button>
      )}
      {/* Sidebar */}
      <aside className="sidebar" style={{ display: collapsed ? 'none' : undefined }}>
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

        <div className="folders-label">Folders</div>
        <button className={`folder-row ${!sharedView && activeCategory === null ? 'active' : ''}`} onClick={() => { setSharedView(false); setActiveCategory(null); }}>
          <FolderIcon /> <span>All notes</span><span className="folder-count">{sharedView ? '' : notes.length}</span>
        </button>
        {categories.map((c) => (
          <button key={c.category} className={`folder-row ${!sharedView && activeCategory === c.category ? 'active' : ''}`} onClick={() => { setSharedView(false); setActiveCategory(c.category); }}>
            <FolderIcon /> <span>{c.category}</span><span className="folder-count">{c.n}</span>
          </button>
        ))}

        <div className="folders-label">Shared</div>
        <button className={`folder-row ${sharedView ? 'active' : ''}`} onClick={() => { setSharedView(true); setSelected(null); setActiveCategory(null); }}>
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
              <button className={mode === 'keyword' ? 'on' : ''} onClick={() => setMode('keyword')}>Keyword</button>
              <button className={mode === 'semantic' ? 'on' : ''} onClick={() => setMode('semantic')}>Semantic</button>
            </div>
          )}
        </div>

        <div className="notes">
          {loading && <div className="hint">Loading…</div>}
          {!loading && visible.length === 0 && (
            <div className="hint">{sharedView ? 'Nothing shared with you yet.' : query ? 'No matches.' : 'No notes yet. Draw in the app and exit to sync.'}</div>
          )}
          {!loading && grouped
            ? grouped.map(([cat, items]) => (
                <div key={cat} className="note-group">
                  <div className="group-head">{cat}<span>{items.length}</span></div>
                  {items.map(renderCard)}
                </div>
              ))
            : visible.map(renderCard)}
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
                        <button className="menu-item" onClick={() => { setDetailMenuOpen(false); setShareFor(selected); }}><ShareIcon /> Share</button>
                        <button className="menu-item danger" onClick={() => deleteNote(selected.id)}><TrashIcon /> Delete note</button>
                      </div>
                    </>
                  )}
                </div>
              )}
            </header>

            {selected.svg ? (
              <div className="canvas" dangerouslySetInnerHTML={{ __html: selected.svg }} />
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
                {selected.ocr_text?.trim()
                  ? <p>{selected.ocr_text}</p>
                  : <p className="muted">{transcribing ? 'Reading your handwriting…' : 'Not transcribed yet — convert your handwriting to clean text.'}</p>}
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

      {shareFor && <ShareDialog note={shareFor} onClose={() => setShareFor(null)} />}
      {askOpen && <AskDialog onClose={() => setAskOpen(false)} onOpenNote={(id) => { setAskOpen(false); openNote(id); }} />}
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
function ShareDialog({ note, onClose }: { note: Note; onClose: () => void }) {
  const [email, setEmail] = useState('');
  const [mode, setMode] = useState<'both' | 'strokes' | 'text'>('both');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const submit = async () => {
    setBusy(true); setMsg(null);
    const res = await fetch('/api/share', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ noteId: note.id, email, mode }) });
    setBusy(false);
    if (res.ok) { setMsg('Shared ✓'); setTimeout(onClose, 800); }
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

// ── Ask-your-notes (RAG) dialog ──
function AskDialog({ onClose, onOpenNote }: { onClose: () => void; onOpenNote: (id: string) => void }) {
  const [q, setQ] = useState('');
  const [busy, setBusy] = useState(false);
  const [res, setRes] = useState<AskResult | null>(null);

  const ask = async () => {
    if (!q.trim()) return;
    setBusy(true); setRes(null);
    const r = await fetch('/api/ask', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ question: q }) });
    setBusy(false);
    setRes(r.ok ? await r.json() : { answer: 'Something went wrong.', sources: [] });
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
        {res && (
          <div className="ask-answer">
            <p>{res.answer}</p>
            {res.sources.length > 0 && (
              <div className="ask-sources">
                {res.sources.map((s) => (
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

// A note card with an Apple-style ⋯ menu (Move / Share / Delete) + swipe-to-delete.
function NoteRow({ note, active, readOnly, categories, onOpen, onDelete, onMove, onShare }: {
  note: Note; active: boolean; readOnly?: boolean; categories: CategoryCount[];
  onOpen: () => void; onDelete: () => void; onMove: (category: string) => void; onShare: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [dragX, setDragX] = useState<number | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const startX = useRef(0); const baseX = useRef(0); const lastX = useRef(0);
  const dragging = useRef(false); const moved = useRef(false);
  const cardRef = useRef<HTMLDivElement>(null);

  const snippet = note.ocr_text?.trim()
    || (note.owner ? `from ${note.owner}` : note.status === 'partial' ? 'Handwriting saved · tap Convert to text' : note.status === 'pending' ? 'Processing…' : 'No text yet');

  useEffect(() => {
    if (!menuOpen) return;
    const onDoc = (e: MouseEvent) => { if (!cardRef.current?.contains(e.target as Node)) setMenuOpen(false); };
    document.addEventListener('click', onDoc);
    return () => document.removeEventListener('click', onDoc);
  }, [menuOpen]);

  const tx = dragX !== null ? dragX : open ? -80 : 0;
  const onPointerDown = (e: React.PointerEvent) => {
    if (readOnly) return;
    if ((e.target as HTMLElement).closest('.note-more, .kebab-menu')) return;
    startX.current = e.clientX; baseX.current = open ? -80 : 0; lastX.current = baseX.current;
    dragging.current = true; moved.current = false;
    e.currentTarget.setPointerCapture(e.pointerId);
  };
  const onPointerMove = (e: React.PointerEvent) => {
    if (!dragging.current) return;
    if (Math.abs(e.clientX - startX.current) > 4) moved.current = true;
    const c = clamp(baseX.current + (e.clientX - startX.current), -92, 0);
    lastX.current = c; setDragX(c);
  };
  const endDrag = () => { if (!dragging.current) return; dragging.current = false; setOpen(lastX.current < -40); setDragX(null); };
  const onClick = () => { if (moved.current) { moved.current = false; return; } if (open) { setOpen(false); return; } onOpen(); };

  const moveTargets = categories.filter((c) => c.category !== (note.category || 'Uncategorized'));

  return (
    <div className="note-row">
      {(open || dragX !== null) && (
        <button className="note-delete-action" onClick={(e) => { e.stopPropagation(); onDelete(); }} aria-label="Delete note"><TrashIcon /></button>
      )}
      <div ref={cardRef} className={`note-card ${active ? 'active' : ''}`} style={{ transform: `translateX(${tx}px)` }}
        onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={endDrag} onPointerCancel={endDrag} onClick={onClick}>
        <div className="note-title">{note.title || 'Untitled note'}</div>
        <div className="note-snippet">{snippet}</div>
        <div className="note-meta">
          {note.category && <span className="tag">{note.category}</span>}
          <span className="date">{formatDate(note.updated_at)}</span>
        </div>

        {!readOnly && (
          <button className="note-more" onClick={(e) => { e.stopPropagation(); setMenuOpen((o) => !o); }} aria-label="Note actions"><KebabIcon /></button>
        )}
        {menuOpen && (
          <div className="kebab-menu" onClick={(e) => e.stopPropagation()}>
            {moveTargets.length > 0 && <div className="menu-label">Move to</div>}
            {moveTargets.map((c) => (
              <button key={c.category} className="menu-item" onClick={() => { setMenuOpen(false); onMove(c.category); }}><FolderIcon /> {c.category}</button>
            ))}
            {moveTargets.length > 0 && <div className="menu-sep" />}
            <button className="menu-item" onClick={() => { setMenuOpen(false); onShare(); }}><ShareIcon /> Share</button>
            <button className="menu-item danger" onClick={() => { setMenuOpen(false); onDelete(); }}><TrashIcon /> Delete</button>
          </div>
        )}
      </div>
    </div>
  );
}
