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
};
type NoteDetail = Note & { svg: string | null };
type Related = { id: string; title: string | null; category: string | null };
type CategoryCount = { category: string; n: number };

export default function Workspace({
  spaces,
  dbError,
  userEmail,
}: {
  spaces: Space[];
  dbError: boolean;
  userEmail: string;
}) {
  const [activeId, setActiveId] = useState<string | undefined>(spaces[0]?.id);
  const [theme, setTheme] = useState<'light' | 'dark'>('light');
  const [query, setQuery] = useState('');
  const [mode, setMode] = useState<'keyword' | 'semantic'>('keyword');
  const [notes, setNotes] = useState<Note[]>([]);
  const [categories, setCategories] = useState<CategoryCount[]>([]);
  const [activeCategory, setActiveCategory] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [selected, setSelected] = useState<NoteDetail | null>(null);
  const [related, setRelated] = useState<Related[]>([]);
  const [transcribing, setTranscribing] = useState(false);
  const [detailMenuOpen, setDetailMenuOpen] = useState(false);

  // ── Theme ──
  useEffect(() => {
    const saved = (localStorage.getItem('sb-theme') as 'light' | 'dark' | null) ??
      (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
    setTheme(saved);
  }, []);
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem('sb-theme', theme);
  }, [theme]);

  // ── Data loading ──
  const loadNotes = useCallback(async () => {
    if (!activeId) return;
    setLoading(true);
    try {
      const params = new URLSearchParams({ space: activeId, mode });
      if (query.trim()) params.set('q', query.trim());
      const res = await fetch(`/api/notes?${params}`, { cache: 'no-store' });
      setNotes(res.ok ? await res.json() : []);
    } finally {
      setLoading(false);
    }
  }, [activeId, query, mode]);

  const loadCategories = useCallback(async () => {
    if (!activeId) return;
    const res = await fetch(`/api/categories?space=${activeId}`, { cache: 'no-store' });
    setCategories(res.ok ? await res.json() : []);
  }, [activeId]);

  useEffect(() => {
    const t = setTimeout(loadNotes, query ? 300 : 0);
    return () => clearTimeout(t);
  }, [loadNotes, query]);
  useEffect(() => { loadCategories(); }, [loadCategories, notes.length]);

  const openNote = async (id: string) => {
    setRelated([]);
    setDetailMenuOpen(false);
    const res = await fetch(`/api/note?id=${id}`, { cache: 'no-store' });
    if (res.ok) setSelected(await res.json());
    fetch(`/api/related?id=${id}`, { cache: 'no-store' }).then(async (r) => r.ok && setRelated(await r.json()));
  };

  const deleteNote = async (id: string) => {
    // Optimistic: drop it from the UI immediately, then persist.
    setNotes((prev) => prev.filter((n) => n.id !== id));
    if (selected?.id === id) {
      setSelected(null);
      setDetailMenuOpen(false);
    }
    await fetch(`/api/note?id=${id}`, { method: 'DELETE' });
    loadCategories();
  };

  const transcribe = async () => {
    if (!selected) return;
    setTranscribing(true);
    await fetch('/api/transcribe', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ id: selected.id }) });
    // Poll until processed.
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

  // Notes filtered by the active "folder" (category).
  const visible = useMemo(
    () => (activeCategory ? notes.filter((n) => (n.category || 'Uncategorized') === activeCategory) : notes),
    [notes, activeCategory],
  );
  // Group for display when browsing everything (no search, no folder filter).
  const grouped = useMemo(() => {
    if (query || activeCategory) return null;
    const map = new Map<string, Note[]>();
    for (const n of visible) {
      const c = n.category || 'Uncategorized';
      if (!map.has(c)) map.set(c, []);
      map.get(c)!.push(n);
    }
    return [...map.entries()];
  }, [visible, query, activeCategory]);

  if (dbError) {
    return (
      <div className="empty-full">
        <h1>Can’t reach the library</h1>
        <p>The web app couldn’t connect to Aurora. Check the AWS env vars in your Vercel project.</p>
      </div>
    );
  }

  const renderCard = (n: Note) => (
    <NoteRow key={n.id} note={n} active={selected?.id === n.id} onOpen={() => openNote(n.id)} onDelete={() => deleteNote(n.id)} />
  );

  return (
    <div className="app">
      {/* Sidebar */}
      <aside className="sidebar">
        <div className="side-top">
          <span className="brand">SpatialBoard</span>
          <button className="theme-toggle" onClick={() => setTheme(theme === 'light' ? 'dark' : 'light')} aria-label="Toggle theme">
            {theme === 'light' ? <MoonIcon /> : <SunIcon />}
          </button>
        </div>

        {spaces.map((s) => (
          <div key={s.id} className="space-block">
            <button className={`space-row ${s.id === activeId ? 'active' : ''}`} onClick={() => { setActiveId(s.id); setSelected(null); setActiveCategory(null); }}>
              <span className="dot" style={{ background: s.color_hex || '#8E8E93' }} />
              {s.name}
            </button>
          </div>
        ))}

        <div className="folders-label">Folders</div>
        <button className={`folder-row ${activeCategory === null ? 'active' : ''}`} onClick={() => setActiveCategory(null)}>
          <FolderIcon /> <span>All notes</span><span className="folder-count">{notes.length}</span>
        </button>
        {categories.map((c) => (
          <button key={c.category} className={`folder-row ${activeCategory === c.category ? 'active' : ''}`} onClick={() => setActiveCategory(c.category)}>
            <FolderIcon /> <span>{c.category}</span><span className="folder-count">{c.n}</span>
          </button>
        ))}

        <div className="account">
          <span className="account-email" title={userEmail}>{userEmail}</span>
          <button className="account-signout" onClick={() => signOut()}>Sign out</button>
        </div>
      </aside>

      {/* List */}
      <section className="list">
        <div className="search">
          <input placeholder="Search notes…" value={query} onChange={(e) => setQuery(e.target.value)} />
          <div className="modes">
            <button className={mode === 'keyword' ? 'on' : ''} onClick={() => setMode('keyword')}>Keyword</button>
            <button className={mode === 'semantic' ? 'on' : ''} onClick={() => setMode('semantic')}>Semantic</button>
          </div>
        </div>

        <div className="notes">
          {loading && <div className="hint">Searching…</div>}
          {!loading && visible.length === 0 && (
            <div className="hint">{query ? 'No matches.' : 'No notes yet. Draw in the app and exit to sync.'}</div>
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
                </div>
              </div>
              <div className="kebab-wrap">
                <button className="kebab-btn" onClick={() => setDetailMenuOpen((o) => !o)} aria-label="Note actions">
                  <KebabIcon />
                </button>
                {detailMenuOpen && (
                  <>
                    <div className="menu-backdrop" onClick={() => setDetailMenuOpen(false)} />
                    <div className="kebab-menu">
                      <button className="menu-item danger" onClick={() => deleteNote(selected.id)}>
                        <TrashIcon /> Delete note
                      </button>
                    </div>
                  </>
                )}
              </div>
            </header>

            {selected.svg ? (
              <div className="canvas" dangerouslySetInnerHTML={{ __html: selected.svg }} />
            ) : (
              <div className="canvas placeholder">{selected.status === 'pending' ? 'Processing…' : 'No rendering'}</div>
            )}

            <section className="transcript">
              <div className="transcript-head">
                <span className="transcript-label">Transcription</span>
                <button className="convert-btn" onClick={transcribe} disabled={transcribing}>
                  {transcribing ? 'Reading…' : selected.ocr_text?.trim() ? 'Re-transcribe' : 'Convert to text'}
                </button>
              </div>
              {selected.ocr_text?.trim()
                ? <p>{selected.ocr_text}</p>
                : <p className="muted">{transcribing ? 'Reading your handwriting…' : 'Not transcribed yet — convert your handwriting to clean text.'}</p>}
            </section>

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

// A note card with an Apple-style ⋯ menu (hover/tap) and swipe-left-to-delete.
function NoteRow({ note, active, onOpen, onDelete }: { note: Note; active: boolean; onOpen: () => void; onDelete: () => void }) {
  const [open, setOpen] = useState(false);      // swiped open (Delete revealed)
  const [dragX, setDragX] = useState<number | null>(null); // live drag offset
  const [menuOpen, setMenuOpen] = useState(false);
  const startX = useRef(0);
  const baseX = useRef(0);
  const lastX = useRef(0);
  const dragging = useRef(false);
  const moved = useRef(false);
  const cardRef = useRef<HTMLDivElement>(null);

  const snippet = note.ocr_text?.trim()
    || (note.status === 'partial' ? 'Handwriting saved · tap Convert to text'
      : note.status === 'pending' ? 'Processing…' : 'No text yet');

  // Close the ⋯ menu on any outside click.
  useEffect(() => {
    if (!menuOpen) return;
    const onDoc = (e: MouseEvent) => {
      if (!cardRef.current?.contains(e.target as Node)) setMenuOpen(false);
    };
    document.addEventListener('click', onDoc);
    return () => document.removeEventListener('click', onDoc);
  }, [menuOpen]);

  const tx = dragX !== null ? dragX : open ? -80 : 0;

  const onPointerDown = (e: React.PointerEvent) => {
    // Don't start a swipe when pressing the ⋯ button or its menu.
    if ((e.target as HTMLElement).closest('.note-more, .kebab-menu')) return;
    startX.current = e.clientX;
    baseX.current = open ? -80 : 0;
    lastX.current = baseX.current;
    dragging.current = true;
    moved.current = false;
    e.currentTarget.setPointerCapture(e.pointerId);
  };
  const onPointerMove = (e: React.PointerEvent) => {
    if (!dragging.current) return;
    if (Math.abs(e.clientX - startX.current) > 4) moved.current = true;
    const clamped = Math.max(-92, Math.min(0, baseX.current + (e.clientX - startX.current)));
    lastX.current = clamped;
    setDragX(clamped);
  };
  const endDrag = () => {
    if (!dragging.current) return;
    dragging.current = false;
    setOpen(lastX.current < -40); // stay open if dragged past threshold
    setDragX(null);
  };
  const onClick = () => {
    if (moved.current) { moved.current = false; return; } // it was a drag, not a tap
    if (open) { setOpen(false); return; }                 // tap closes the revealed Delete
    onOpen();
  };

  return (
    <div className="note-row">
      {(open || dragX !== null) && (
        <button className="note-delete-action" onClick={(e) => { e.stopPropagation(); onDelete(); }} aria-label="Delete note">
          <TrashIcon />
        </button>
      )}
      <div
        ref={cardRef}
        className={`note-card ${active ? 'active' : ''}`}
        style={{ transform: `translateX(${tx}px)` }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={endDrag}
        onPointerCancel={endDrag}
        onClick={onClick}
      >
        <div className="note-title">{note.title || 'Untitled note'}</div>
        <div className="note-snippet">{snippet}</div>
        <div className="note-meta">
          {note.category && <span className="tag">{note.category}</span>}
          <span className="date">{formatDate(note.updated_at)}</span>
        </div>

        <button
          className="note-more"
          onClick={(e) => { e.stopPropagation(); setMenuOpen((o) => !o); }}
          aria-label="Note actions"
        >
          <KebabIcon />
        </button>
        {menuOpen && (
          <div className="kebab-menu" onClick={(e) => e.stopPropagation()}>
            <button className="menu-item danger" onClick={() => { setMenuOpen(false); onDelete(); }}>
              <TrashIcon /> Delete
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
