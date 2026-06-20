import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { shouldAnimate } from '../lib/motion';
import HeroCanvas from './HeroCanvas';
import Magnetic from './Magnetic';
import './Hero.css';

export default function Hero() {
  const heroRef = useRef(null);

  useEffect(() => {
    if (!shouldAnimate()) return;
    const ctx = gsap.context(() => {
      const tl = gsap.timeline({ defaults: { ease: 'power4.out' } });
      tl.fromTo('.hero-tag', { y: 16, opacity: 0 }, { y: 0, opacity: 1, duration: 0.8, stagger: 0.06 }, 0.25)
        .fromTo('.hero-line span', { yPercent: 120 }, { yPercent: 0, duration: 1.1, stagger: 0.09 }, 0.3)
        .fromTo('.hero-lede', { y: 22, opacity: 0 }, { y: 0, opacity: 1, duration: 0.9 }, '-=0.6')
        .fromTo('.hero-cta', { y: 18, opacity: 0 }, { y: 0, opacity: 1, duration: 0.7, stagger: 0.08 }, '-=0.55')
        .fromTo('.hero-meta-item', { opacity: 0 }, { opacity: 1, duration: 0.8, stagger: 0.08 }, '-=0.4');
    }, heroRef);
    return () => ctx.revert();
  }, []);

  return (
    <header ref={heroRef} className="hero" id="top">
      <HeroCanvas />
      <div className="container hero-inner">
        <div className="hero-tags">
          <span className="hero-tag eyebrow">SpatialBoard</span>
          <span className="hero-tag hero-tag--muted">iOS capture · AWS web companion</span>
        </div>

        <h1 className="hero-headline display">
          <span className="hero-line"><span>Handwriting,</span></span>
          <span className="hero-line"><span>anchored in space —</span></span>
          <span className="hero-line"><span><em className="accent">indexed</em> by AWS.</span></span>
        </h1>

        <p className="hero-lede lede">
          Write notes by hand in 3D space with LiDAR and hand gestures. A deliberate
          AWS pipeline turns that spatial brain-dump into a calm, searchable,
          auto-categorized library you can read anywhere.
        </p>

        <div className="hero-ctas">
          <Magnetic>
            <a
              href="https://youtu.be/NDZyi6bChMY"
              target="_blank"
              rel="noopener noreferrer"
              className="hero-cta hero-cta--primary"
              id="hero-demo-btn"
            >
              Watch the demo
            </a>
          </Magnetic>
          <Magnetic>
            <a
              href="https://github.com/g4ntavya/Spatial-Board"
              target="_blank"
              rel="noopener noreferrer"
              className="hero-cta hero-cta--ghost"
              id="hero-source-btn"
            >
              View source
            </a>
          </Magnetic>
        </div>

        <div className="hero-meta">
          <div className="hero-meta-item">
            <span className="hero-meta-k">Capture</span>
            <span className="hero-meta-v">ARKit · RealityKit · Vision</span>
          </div>
          <div className="hero-meta-item">
            <span className="hero-meta-k">Index</span>
            <span className="hero-meta-v">Aurora Serverless v2 · pgvector</span>
          </div>
          <div className="hero-meta-item">
            <span className="hero-meta-k">Intelligence</span>
            <span className="hero-meta-v">Bedrock — Titan · Claude</span>
          </div>
          <div className="hero-meta-item">
            <span className="hero-meta-k">Surface</span>
            <span className="hero-meta-v">Next.js on Vercel</span>
          </div>
        </div>
      </div>
    </header>
  );
}
