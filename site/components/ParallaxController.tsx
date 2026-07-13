"use client";

import { useEffect, useRef, type ReactNode } from "react";

export default function ParallaxController({ children }: { children: ReactNode }) {
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
      const strength = layoutStrength;
      const rotationStrength = layoutStrength;

      const slowX = (48 * progress + 12 * wave) * strength;
      const slowY = (-80 * progress + 10 * counterWave) * strength;
      const midX = (-70 * progress - 18 * wave) * strength;
      const midY = (145 * progress + 24 * counterWave) * strength;
      const fastX = (120 * progress + 32 * wave) * strength;
      const fastY = (-220 * progress + 42 * counterWave) * strength;
      const nebulaX = (-80 * progress - 38 * wave) * strength;
      const nebulaY = (140 * progress + 36 * counterWave) * strength;

      field.style.setProperty("--slow-x", `${slowX.toFixed(2)}px`);
      field.style.setProperty("--slow-y", `${slowY.toFixed(2)}px`);
      field.style.setProperty(
        "--slow-r",
        `${(-1.5 * progress * rotationStrength).toFixed(3)}deg`,
      );
      field.style.setProperty("--mid-x", `${midX.toFixed(2)}px`);
      field.style.setProperty("--mid-y", `${midY.toFixed(2)}px`);
      field.style.setProperty(
        "--mid-r",
        `${(2.2 * progress * rotationStrength).toFixed(3)}deg`,
      );
      field.style.setProperty("--fast-x", `${fastX.toFixed(2)}px`);
      field.style.setProperty("--fast-y", `${fastY.toFixed(2)}px`);
      field.style.setProperty(
        "--fast-r",
        `${(-2.8 * progress * rotationStrength).toFixed(3)}deg`,
      );
      field.style.setProperty("--nebula-x", `${nebulaX.toFixed(2)}px`);
      field.style.setProperty("--nebula-y", `${nebulaY.toFixed(2)}px`);

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
