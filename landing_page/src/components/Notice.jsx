import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { shouldAnimate } from '../lib/motion';
import './Notice.css';

gsap.registerPlugin(ScrollTrigger);

export default function Notice() {
  const sectionRef = useRef(null);

  useEffect(() => {
    if (!shouldAnimate()) return;
    const ctx = gsap.context(() => {
      gsap.fromTo('.idea-rule', { scaleX: 0 }, {
        scaleX: 1, duration: 1.2, ease: 'power3.inOut',
        scrollTrigger: { trigger: sectionRef.current, start: 'top 82%' },
      });
      gsap.fromTo('.idea-reveal', { y: 28, opacity: 0 }, {
        y: 0, opacity: 1, duration: 0.85, stagger: 0.1, ease: 'power3.out',
        scrollTrigger: { trigger: sectionRef.current, start: 'top 76%' },
      });
    }, sectionRef);
    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} className="idea section" id="idea">
      <div className="container">
        <div className="idea-rule rule" />

        <div className="idea-head">
          <span className="idea-reveal eyebrow">The idea</span>
          <h2 className="idea-reveal idea-statement display">
            The relationship between the two layers is
            <em className="accent"> transformation</em>, not mirroring.
          </h2>
        </div>

        <div className="idea-flow">
          <div className="idea-reveal idea-card">
            <span className="idea-card-k">Before</span>
            <h3 className="idea-card-title">A messy spatial brain-dump</h3>
            <p className="idea-card-desc">
              Equations, diagrams and to-dos drawn by hand and left floating across a
              room. Captured on iPhone with LiDAR — fast, physical, unindexed.
            </p>
          </div>

          <div className="idea-reveal idea-arrow" aria-hidden="true">
            <span>projection · OCR · embedding · categorization</span>
            <div className="idea-arrow-line" />
          </div>

          <div className="idea-reveal idea-card idea-card--after">
            <span className="idea-card-k">After</span>
            <h3 className="idea-card-title">A clean, indexed library</h3>
            <p className="idea-card-desc">
              Each cluster of strokes becomes a titled, categorized note — readable,
              full-text and semantically searchable, mirrored to the web in seconds.
            </p>
          </div>
        </div>

        <p className="idea-reveal idea-foot">
          SpatialBoard is currently distributed as an interactive demo and open
          source. <a href="https://youtu.be/sIWVNEsMZm8" target="_blank" rel="noopener noreferrer" id="idea-demo-link">Watch the demo</a> or
          <a href="https://github.com/g4ntavya/Spatial-Board" target="_blank" rel="noopener noreferrer" id="idea-source-link"> read the source</a>.
        </p>
      </div>
    </section>
  );
}
