"use client";

import { useEffect, useRef, type ReactNode } from "react";

/**
 * The depth layers of the background field. Each maps to a set of
 * `--<name>-{x,y,r}` custom properties consumed by space.css. Coefficients:
 *   x: [progress, wave]         → drift along the page + a bounded sway
 *   y: [progress, counterWave]  → drift along the page + a bounded bob
 *   r: rotation-per-progress    → optional slow tilt (omit for no rotation)
 */
const LAYERS: {
  name: string;
  x: [number, number];
  y: [number, number];
  r?: number;
}[] = [
  { name: "slow", x: [48, 12], y: [-80, 10], r: -1.5 },
  { name: "mid", x: [-70, -18], y: [145, 24], r: 2.2 },
  { name: "fast", x: [120, 32], y: [-220, 42], r: -2.8 },
  { name: "nebula", x: [-80, -38], y: [140, 36] },
];

export default function ParallaxController({
  children,
}: {
  children: ReactNode;
}) {
  const fieldRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const field = fieldRef.current;
    if (!field) return;

    const mobileLayout = window.matchMedia("(max-width: 1179px)");

    let frame = 0;
    let targetScroll = window.scrollY;
    let renderedScroll = targetScroll;

    const clamp = (value: number, min: number, max: number) =>
      Math.min(max, Math.max(min, value));

    const render = () => {
      frame = 0;

      // Trail the scrollbar slightly to give the background layers weight.
      renderedScroll += (targetScroll - renderedScroll) * 0.13;

      const maxScroll = Math.max(
        document.documentElement.scrollHeight - window.innerHeight,
        1,
      );
      const progress = clamp(renderedScroll / maxScroll, 0, 1);

      // The progress term creates a page-long drift. The bounded waves keep
      // the field moving through long sections without allowing a sparse SVG
      // layer to disappear permanently beyond the viewport.
      const wave = Math.sin(renderedScroll / 720);
      const counterWave = Math.cos(renderedScroll / 980) - 1;
      const layoutStrength = mobileLayout.matches ? 0.68 : 1;

      for (const layer of LAYERS) {
        const x = (layer.x[0] * progress + layer.x[1] * wave) * layoutStrength;
        const y =
          (layer.y[0] * progress + layer.y[1] * counterWave) * layoutStrength;
        field.style.setProperty(`--${layer.name}-x`, `${x.toFixed(2)}px`);
        field.style.setProperty(`--${layer.name}-y`, `${y.toFixed(2)}px`);
        if (layer.r !== undefined) {
          const r = layer.r * progress * layoutStrength;
          field.style.setProperty(`--${layer.name}-r`, `${r.toFixed(3)}deg`);
        }
      }

      if (Math.abs(targetScroll - renderedScroll) > 0.1) {
        frame = requestAnimationFrame(render);
      } else {
        renderedScroll = targetScroll;
      }
    };

    const schedule = () => {
      if (!frame) frame = requestAnimationFrame(render);
    };
    const onScroll = () => {
      targetScroll = window.scrollY;
      schedule();
    };
    const onEnvironmentChange = () => {
      targetScroll = window.scrollY;
      renderedScroll = targetScroll;
      schedule();
    };

    render();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onEnvironmentChange, { passive: true });
    mobileLayout.addEventListener("change", onEnvironmentChange);

    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onEnvironmentChange);
      mobileLayout.removeEventListener("change", onEnvironmentChange);
      if (frame) cancelAnimationFrame(frame);
    };
  }, []);

  return (
    <div className="site-parallax" ref={fieldRef} aria-hidden="true">
      {children}
    </div>
  );
}
