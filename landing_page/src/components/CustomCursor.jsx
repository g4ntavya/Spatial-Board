import { useEffect, useRef } from 'react';
import { shouldAnimate } from '../lib/motion';
import './CustomCursor.css';

/* A small dot + a softly-trailing ring that grows over interactive elements.
   Native cursor is only hidden once this mounts (so it never disappears if JS
   is off), and it stays off for touch / reduced-motion. */
export default function CustomCursor() {
  const dot = useRef(null);
  const ring = useRef(null);

  useEffect(() => {
    if (!shouldAnimate() || window.matchMedia('(pointer: coarse)').matches) return;
    const d = dot.current, r = ring.current;
    if (!d || !r) return;

    document.body.classList.add('has-cursor');
    let mx = window.innerWidth / 2, my = window.innerHeight / 2;
    let rx = mx, ry = my, raf;

    const move = (e) => {
      mx = e.clientX; my = e.clientY;
      d.style.transform = `translate(${mx}px, ${my}px)`;
    };
    const loop = () => {
      rx += (mx - rx) * 0.18; ry += (my - ry) * 0.18;
      r.style.transform = `translate(${rx}px, ${ry}px)`;
      raf = requestAnimationFrame(loop);
    };
    const over = (e) => { if (e.target.closest('a, button, .magnetic, input, textarea, summary')) r.classList.add('hover'); };
    const out = (e) => { if (e.target.closest('a, button, .magnetic, input, textarea, summary')) r.classList.remove('hover'); };

    window.addEventListener('mousemove', move);
    document.addEventListener('mouseover', over);
    document.addEventListener('mouseout', out);
    loop();

    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener('mousemove', move);
      document.removeEventListener('mouseover', over);
      document.removeEventListener('mouseout', out);
      document.body.classList.remove('has-cursor');
    };
  }, []);

  return (<>
    <div ref={dot} className="cursor-dot" aria-hidden="true" />
    <div ref={ring} className="cursor-ring" aria-hidden="true" />
  </>);
}
