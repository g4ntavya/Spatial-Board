import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import './Showcase.css';

gsap.registerPlugin(ScrollTrigger);

const SECTION_1 = {
  id: 'core-system',
  eyebrow: '01 / Core Canvas & Gesture Engine',
  title: 'The physical-digital workspace interface',
  items: [
    {
      num: '01',
      id: 'img1',
      title: 'Onboarding & Landing',
      desc: 'Onboarding and landing page interface that initializes calibration and walks you through spatial controls.',
      src: '/assets/img1.png',
      alt: 'SpatialBoard onboarding and landing interface screen',
      type: 'portrait',
    },
    {
      num: '02',
      id: 'img2',
      title: 'Hand Gesture Drawing',
      desc: 'Drawing via hand gestures using the Vision framework. Pinch thumb and index to paint lines dynamically in 3D.',
      src: '/assets/img2.png',
      alt: 'Pinch gesture drawing live strokes in AR space',
      type: 'landscape',
    },
    {
      num: '03',
      id: 'img3',
      title: 'Vector Coordinate Projection',
      desc: 'Vector coordinate projection and persistent notes anchored across 3D space via ARKit WorldAnchors.',
      src: '/assets/img3.png',
      alt: 'Persistent spatial vector strokes locked in real room space',
      type: 'landscape', // Styled as landscape inside the right column stack
    },
  ],
};

const SECTION_2 = {
  id: 'environments',
  eyebrow: '02 / Environments & AI Intelligence',
  title: 'Context-aware culling and spaces switcher',
  items: [
    {
      num: '04',
      id: 'img_ui',
      title: 'App Interface & UI',
      desc: 'The complete UI dashboard of the app, showcasing your active workspace, current drawing/gesture state, and system features.',
      src: '/assets/1_.png',
      alt: 'Floating system UI panel showing workspaces and drawing tools',
      type: 'landscape',
    },
    {
      num: '05',
      id: 'img_spaces',
      title: 'Spaces Feature',
      desc: 'Create, isolate, and switch between separate workspaces. Saves tags so you only load what belongs to the active space.',
      src: '/assets/2_.png',
      alt: 'Active spatial environments switcher dashboard',
      type: 'landscape',
    },
    {
      num: '06',
      id: 'img_move',
      title: 'Move Feature & Folders',
      desc: 'Pinch to select and drag strokes or folders. Billboards the strokes during movement so you can adjust their 3D rotation.',
      src: '/assets/4_.png',
      alt: 'Folder capsules and billboard stroke selection movements',
      type: 'landscape',
    },
    {
      num: '07',
      id: 'img_kon_gesture',
      title: 'Triggering Kon Gesture',
      desc: 'Target physical mathematical equations using focused coordinate culling, preparing to activate the AI solver.',
      src: '/assets/5_.png',
      alt: 'OCR culling box highlighting mathematical equation',
      type: 'landscape',
    },
    {
      num: '08',
      id: 'img_kon_solver',
      title: 'Kon Live Math Solving',
      desc: 'Solves targeted mathematical strokes via Gemini and displays structural, step-by-step solutions in your own handwriting style.',
      src: '/assets/6_.png',
      alt: 'Step by step math answers rendered in user handwriting',
      type: 'landscape',
      isFullWidth: true,
    },
  ],
};

export default function Showcase() {
  const sectionRef = useRef(null);

  useEffect(() => {
    const ctx = gsap.context(() => {
      // Intro header animations
      gsap.fromTo(
        '.showcase-eyebrow, .showcase-title',
        { y: 50, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.9,
          stagger: 0.12,
          ease: 'power3.out',
          scrollTrigger: { trigger: sectionRef.current, start: 'top 85%' },
        }
      );

      // Section 1 reveals
      gsap.fromTo(
        '#core-system .showcase-subheading',
        { y: 30, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.7,
          ease: 'power3.out',
          scrollTrigger: { trigger: '#core-system', start: 'top 80%' },
        }
      );

      gsap.fromTo(
        '#core-system .showcase-item',
        { y: 60, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.9,
          stagger: 0.15,
          ease: 'power3.out',
          scrollTrigger: { trigger: '#core-system .showcase-grid-sec1', start: 'top 82%' },
        }
      );

      // Section 2 reveals
      gsap.fromTo(
        '#environments .showcase-subheading',
        { y: 30, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.7,
          ease: 'power3.out',
          scrollTrigger: { trigger: '#environments', start: 'top 80%' },
        }
      );

      gsap.fromTo(
        '#environments .showcase-item',
        { y: 60, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.9,
          stagger: 0.15,
          ease: 'power3.out',
          scrollTrigger: { trigger: '#environments .showcase-grid-sec2', start: 'top 82%' },
        }
      );
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} className="showcase" id="showcase">
      <div className="container">
        <div className="showcase-header">
          <span className="showcase-eyebrow">Visual System Walkthrough</span>
          <h2 className="showcase-title">See SpatialBoard in Action</h2>
        </div>

        <div className="showcase-gallery-sections">
          {/* Section 1: Core System & Drawing */}
          <div className="showcase-section" id={SECTION_1.id}>
            <div className="showcase-subheading">
              <span className="showcase-sub-eyebrow">{SECTION_1.eyebrow}</span>
              <h3 className="showcase-sub-title">{SECTION_1.title}</h3>
            </div>

            {/* Asymmetric magazine grid layout */}
            <div className="showcase-grid-sec1">
              {SECTION_1.items.map((item) => (
                <div
                  key={item.num}
                  className={`showcase-item showcase-item--${item.id === 'img1' ? 'portrait' : 'landscape'}`}
                >
                  <div className="showcase-frame">
                    <img src={item.src} alt={item.alt} loading="lazy" />
                  </div>
                  <div className="showcase-meta">
                    <span className="showcase-num">{item.num}</span>
                    <div>
                      <h4 className="showcase-meta-title">{item.title}</h4>
                      <p className="showcase-meta-desc">{item.desc}</p>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div>

          {/* Section 2: Environments & AI Intelligence */}
          <div className="showcase-section" id={SECTION_2.id}>
            <div className="showcase-subheading">
              <span className="showcase-sub-eyebrow">{SECTION_2.eyebrow}</span>
              <h3 className="showcase-sub-title">{SECTION_2.title}</h3>
            </div>

            {/* 2-Column Landscapes Stagger Grid with fullwidth ending item */}
            <div className="showcase-grid-sec2">
              {SECTION_2.items.map((item) => (
                <div
                  key={item.num}
                  className={`showcase-item showcase-item--landscape ${
                    item.isFullWidth ? 'showcase-item--fullwidth' : ''
                  }`}
                >
                  <div className="showcase-frame">
                    <img src={item.src} alt={item.alt} loading="lazy" />
                  </div>
                  <div className="showcase-meta">
                    <span className="showcase-num">{item.num}</span>
                    <div>
                      <h4 className="showcase-meta-title">{item.title}</h4>
                      <p className="showcase-meta-desc">{item.desc}</p>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
