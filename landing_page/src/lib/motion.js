/* Returns false when the visitor has requested reduced motion. Components bail
   out of their reveal animations in that case, leaving the plain CSS (fully
   visible) state, so content is never stuck at opacity 0. */
export function shouldAnimate() {
  if (typeof window === 'undefined') return true;
  return !window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}
