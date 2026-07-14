import { useEffect, useState } from "react";
import type { RefObject } from "react";
import type { Kind } from "@/components/demo/data";
import { ENTER_FROM, FLOAT } from "@/components/demo/geometry";

const DAMPING_RATIO = 0.55; // < 1 → slight overshoot

/**
 * Floating cards: each chip trails page scroll on its own underdamped spring —
 * it drifts after the page moves and settles with a small natural bounce, so
 * the arc feels physically detached. A slow per-chip sine (idle bob) rides on
 * top. Each chip is server-rendered ENTER_FROM px below rest, so the spring
 * visibly lifts it into place on load. Written to the `--float-y` variable
 * every chip transform (rest, launch, wiggle) already includes.
 *
 * Returns whether every chip has passed its first upward apex — the moment the
 * arrow-reveal and drop-zone intro animations are armed.
 */
export function useChipFloat(arcRef: RefObject<HTMLDivElement | null>) {
  const [chipsReachedApex, setChipsReachedApex] = useState(false);

  useEffect(() => {
    const chips = Array.from(
      arcRef.current?.querySelectorAll<HTMLElement>(".chip") ?? [],
    );
    if (chips.length === 0) return;
    // Each chip's spring/bob personality lives in FLOAT (geometry.ts), keyed
    // by the kind the chip carries in data-kind — never by DOM index.
    const kinds = chips.map((el) => el.dataset.kind as Kind);
    const pos = kinds.map((k) => ENTER_FROM[k]);
    const vel = chips.map(() => 0);
    const reachedApex = chips.map(() => false);
    let entranceApexFinished = false;
    let raf = 0;
    let last = performance.now();

    const tick = (now: number) => {
      const dt = Math.min(0.048, (now - last) / 1000);
      last = now;
      const t = now / 1000;
      chips.forEach((el, i) => {
        const { drift, stiff, bobAmp, bobPeriod, bobPhase } = FLOAT[kinds[i]];
        const target = window.scrollY * drift;
        const c = 2 * Math.sqrt(stiff) * DAMPING_RATIO;
        const previousVelocity = vel[i];
        vel[i] += ((target - pos[i]) * stiff - vel[i] * c) * dt;
        pos[i] += vel[i] * dt;
        // The first upward overshoot ends when velocity flips from rising
        // (negative Y) to falling (positive Y) above the resting position.
        if (
          !reachedApex[i] &&
          previousVelocity < 0 &&
          vel[i] >= 0 &&
          pos[i] < target
        ) {
          reachedApex[i] = true;
        }
        const bob = bobAmp * Math.sin((2 * Math.PI * t) / bobPeriod + bobPhase);
        el.style.setProperty("--float-y", `${(pos[i] + bob).toFixed(2)}px`);
      });
      if (!entranceApexFinished && reachedApex.every(Boolean)) {
        entranceApexFinished = true;
        setChipsReachedApex(true);
      }
      // never stops: the bob runs whenever the tab is visible (rAF pauses
      // itself in background tabs)
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [arcRef]);

  return chipsReachedApex;
}
