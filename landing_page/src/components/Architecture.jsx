import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import './Architecture.css';

gsap.registerPlugin(ScrollTrigger);

const layers = [
  {
    name: 'Frontend',
    accent: '#E52222',
    items: ['ARCanvasView', 'DrawingOverlay', 'OnboardingView', 'SpacesPickerView'],
  },
  {
    name: 'Services',
    accent: '#F5E6C8',
    items: ['ARSessionManager', 'GestureRecognizer', 'StrokeProcessor', 'Kon'],
  },
  {
    name: 'Data & AI',
    accent: '#4A8FE7',
    items: ['SwiftData', 'GeminiService', 'CharacterSegmenter', 'MetalStrokeProcessor'],
  },
];

export default function Architecture() {
  const sectionRef = useRef(null);

  useEffect(() => {
    const ctx = gsap.context(() => {
      gsap.fromTo(
        '.arch-eyebrow, .arch-title',
        { y: 50, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.9,
          stagger: 0.12,
          ease: 'power3.out',
          scrollTrigger: { trigger: sectionRef.current, start: 'top 80%' },
        }
      );

      gsap.fromTo(
        '.arch-column',
        { y: 50, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.8,
          stagger: 0.15,
          ease: 'power3.out',
          scrollTrigger: { trigger: '.arch-columns', start: 'top 82%' },
        }
      );
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} className="architecture" id="architecture">
      <div className="container">
        <div className="arch-header">
          <span className="arch-eyebrow">Architecture</span>
          <h2 className="arch-title">Three layers, clean separation</h2>
        </div>

        <div className="arch-columns">
          {layers.map((layer, i) => (
            <div
              key={i}
              className="arch-column"
              style={{ '--accent': layer.accent }}
              id={`arch-layer-${i}`}
            >
              <h3 className="arch-column-name">{layer.name}</h3>
              <ul className="arch-column-list">
                {layer.items.map((item, j) => (
                  <li key={j} className="arch-column-item">
                    <code>{item}</code>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
