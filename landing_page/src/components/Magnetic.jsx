import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { shouldAnimate } from '../lib/motion';

/* Wraps an element so it's gently "pulled" toward the cursor (Codrops-style
   magnetic button). Disabled for reduced-motion and touch. */
export default function Magnetic({ children, strength = 0.4 }) {
  const ref = useRef(null);

  useEffect(() => {
    if (!shouldAnimate() || window.matchMedia('(pointer: coarse)').matches) return;
    const el = ref.current;
    if (!el) return;
    const xTo = gsap.quickTo(el, 'x', { duration: 0.5, ease: 'power3.out' });
    const yTo = gsap.quickTo(el, 'y', { duration: 0.5, ease: 'power3.out' });
    const move = (e) => {
      const r = el.getBoundingClientRect();
      xTo((e.clientX - (r.left + r.width / 2)) * strength);
      yTo((e.clientY - (r.top + r.height / 2)) * strength);
    };
    const reset = () => { xTo(0); yTo(0); };
    el.addEventListener('mousemove', move);
    el.addEventListener('mouseleave', reset);
    return () => { el.removeEventListener('mousemove', move); el.removeEventListener('mouseleave', reset); };
  }, [strength]);

  return <span ref={ref} className="magnetic">{children}</span>;
}
