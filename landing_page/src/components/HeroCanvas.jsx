import { useEffect, useRef } from 'react';
import { shouldAnimate } from '../lib/motion';

/* A monochrome WebGL point-field — slowly drifting "notes anchored in space",
   with depth + gentle mouse parallax. Bone points on the dark page; no gradients.
   Pure WebGL (no three.js). Degrades to nothing if WebGL is unavailable, and to
   a single static frame under reduced-motion. */

const VERT = `
attribute vec3 a_pos;     // x, y in clip-ish space; z = depth 0..1
attribute float a_seed;
uniform float u_time;
uniform vec2  u_mouse;
uniform float u_dpr;
varying float v_alpha;
void main() {
  vec2 p = a_pos.xy;
  float ph = a_seed * 6.2831853;
  p.x += 0.025 * sin(u_time * 0.20 + ph);
  p.y += 0.025 * cos(u_time * 0.17 + ph * 1.3);
  p += u_mouse * (0.012 + a_pos.z * 0.05);     // parallax: nearer points move more
  gl_Position = vec4(p, 0.0, 1.0);
  gl_PointSize = (1.1 + a_pos.z * 3.0) * u_dpr;
  v_alpha = 0.05 + a_pos.z * 0.42;
}`;

const FRAG = `
precision mediump float;
varying float v_alpha;
void main() {
  float d = distance(gl_PointCoord, vec2(0.5));
  float a = smoothstep(0.5, 0.12, d) * v_alpha;
  if (a <= 0.001) discard;
  gl_FragColor = vec4(0.953, 0.937, 0.902, a);  // bone #f3efe6
}`;

function compile(gl, type, src) {
  const s = gl.createShader(type);
  if (!s) return null; // context lost / unavailable
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
    console.warn('shader compile failed:', gl.getShaderInfoLog(s));
    gl.deleteShader(s);
    return null;
  }
  return s;
}

export default function HeroCanvas() {
  const ref = useRef(null);

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const gl = canvas.getContext('webgl', { antialias: true, alpha: true, premultipliedAlpha: false });
    if (!gl || gl.isContextLost()) return; // no WebGL / lost → just the dark hero, no crash

    // If the GPU drops the context at runtime, stop the loop instead of throwing.
    const onLost = (e) => e.preventDefault();
    canvas.addEventListener('webglcontextlost', onLost, false);

    const vs = compile(gl, gl.VERTEX_SHADER, VERT);
    const fs = compile(gl, gl.FRAGMENT_SHADER, FRAG);
    if (!vs || !fs) return;
    const prog = gl.createProgram();
    gl.attachShader(prog, vs); gl.attachShader(prog, fs); gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
      console.warn('program link failed:', gl.getProgramInfoLog(prog));
      return;
    }
    gl.useProgram(prog);

    // points: [x, y, z, seed] per vertex
    const N = 900;
    const data = new Float32Array(N * 4);
    for (let i = 0; i < N; i++) {
      data[i * 4 + 0] = (Math.random() * 2 - 1) * 1.15;
      data[i * 4 + 1] = (Math.random() * 2 - 1) * 1.15;
      data[i * 4 + 2] = Math.random();
      data[i * 4 + 3] = Math.random();
    }
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);

    const aPos = gl.getAttribLocation(prog, 'a_pos');
    const aSeed = gl.getAttribLocation(prog, 'a_seed');
    gl.enableVertexAttribArray(aPos);
    gl.vertexAttribPointer(aPos, 3, gl.FLOAT, false, 16, 0);
    gl.enableVertexAttribArray(aSeed);
    gl.vertexAttribPointer(aSeed, 1, gl.FLOAT, false, 16, 12);

    const uTime = gl.getUniformLocation(prog, 'u_time');
    const uMouse = gl.getUniformLocation(prog, 'u_mouse');
    const uDpr = gl.getUniformLocation(prog, 'u_dpr');

    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.clearColor(0, 0, 0, 0);

    let dpr = Math.min(window.devicePixelRatio || 1, 2);
    const resize = () => {
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      const w = canvas.clientWidth, h = canvas.clientHeight;
      canvas.width = Math.max(1, Math.floor(w * dpr));
      canvas.height = Math.max(1, Math.floor(h * dpr));
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.uniform1f(uDpr, dpr);
    };
    resize();
    window.addEventListener('resize', resize);

    const target = { x: 0, y: 0 };
    const cur = { x: 0, y: 0 };
    const onMove = (e) => {
      target.x = (e.clientX / window.innerWidth) * 2 - 1;
      target.y = -((e.clientY / window.innerHeight) * 2 - 1);
    };
    window.addEventListener('mousemove', onMove);

    const draw = (t) => {
      cur.x += (target.x - cur.x) * 0.05;
      cur.y += (target.y - cur.y) * 0.05;
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.uniform1f(uTime, t * 0.001);
      gl.uniform2f(uMouse, cur.x, cur.y);
      gl.drawArrays(gl.POINTS, 0, N);
    };

    let raf;
    if (shouldAnimate()) {
      const loop = (t) => { if (!document.hidden) draw(t); raf = requestAnimationFrame(loop); };
      raf = requestAnimationFrame(loop);
    } else {
      draw(0); // single static frame
    }

    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener('resize', resize);
      window.removeEventListener('mousemove', onMove);
      canvas.removeEventListener('webglcontextlost', onLost, false);
      // NOTE: do NOT call loseContext() here — under StrictMode's mount→unmount→
      // remount the canvas is reused, and losing the context breaks the remount.
    };
  }, []);

  return <canvas ref={ref} className="hero-canvas" aria-hidden="true" />;
}
