import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import './Features.css';

gsap.registerPlugin(ScrollTrigger);

const features = [
  {
    num: '01',
    title: 'Spatial Canvas',
    desc: 'Notes anchored to real-world coordinates using ARKit WorldAnchors. Persistent across sessions via SwiftData with depth-aware drawing plane locking.',
  },
  {
    num: '02',
    title: 'Hand Gestures',
    desc: 'Pinch to draw, two-hand pinch to select, palm to move, open palm to erase. Real-time landmark detection via the Vision framework.',
  },
  {
    num: '03',
    title: '3D Drawing',
    desc: 'Strokes captured as bezier curves, rendered as 3D tube meshes via RealityKit MeshResource. Partial erasing with segment splitting.',
  },
  {
    num: '04',
    title: 'Kon Math Solver',
    desc: 'Captures equation strokes from the AR view and sends optimized images to Gemini. Writes solutions back in your handwriting style.',
  },
  {
    num: '05',
    title: 'Style Imitation',
    desc: 'Onboarding captures your A–Z letterforms. Kon continuously learns from your strokes, rendering generated answers in your style.',
  },
  {
    num: '06',
    title: 'Spatial Workspaces',
    desc: 'Multiple named workspaces with animated transitions. Content tagged with spaceID and loaded per active space only.',
  },
];

export default function Features() {
  const sectionRef = useRef(null);

  useEffect(() => {
    const ctx = gsap.context(() => {
      /* Section title */
      gsap.fromTo(
        '.features-heading',
        { y: 60, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 1,
          ease: 'power3.out',
          scrollTrigger: { trigger: sectionRef.current, start: 'top 80%' },
        }
      );

      /* Staggered row reveals */
      gsap.fromTo(
        '.feature-row',
        { y: 40, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.7,
          stagger: 0.1,
          ease: 'power3.out',
          scrollTrigger: { trigger: '.features-list', start: 'top 85%' },
        }
      );
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} className="features" id="features">
      <div className="container">
        <div className="features-heading">
          <span className="features-eyebrow">Capabilities</span>
          <h2 className="features-title">
            Six systems, one spatial experience
          </h2>
        </div>
        <div className="features-list">
          {features.map((f) => (
            <div key={f.num} className="feature-row" id={`feature-${f.num}`}>
              <span className="feature-num">{f.num}</span>
              <h3 className="feature-name">{f.title}</h3>
              <p className="feature-desc">{f.desc}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
