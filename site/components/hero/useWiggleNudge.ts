import { useEffect, useRef, useState } from "react";
import { NUDGE_DURATION_MS, NUDGE_INTERVAL_MS } from "./constants";

/**
 * The periodic "you can drag me" hint: the movie chip wiggles on a timer until
 * the visitor engages with any chip (drag or tap), then never again.
 * `markInteracted` is the off-switch.
 */
export function useWiggleNudge() {
  const [wiggle, setWiggle] = useState(false);
  const interactedRef = useRef(false);

  useEffect(() => {
    let resetTimer: ReturnType<typeof setTimeout> | null = null;
    const nudge = () => {
      if (interactedRef.current) return;
      setWiggle(true);
      if (resetTimer) clearTimeout(resetTimer);
      resetTimer = setTimeout(() => {
        resetTimer = null;
        setWiggle(false);
      }, NUDGE_DURATION_MS);
    };
    // Give visitors time to take in the hero and the arrow entrance before
    // the movie chip offers its first subtle interaction hint.
    const repeat = setInterval(nudge, NUDGE_INTERVAL_MS);
    return () => {
      clearInterval(repeat);
      if (resetTimer) clearTimeout(resetTimer);
    };
  }, []);

  const markInteracted = () => {
    interactedRef.current = true;
    setWiggle(false);
  };

  return { wiggle, markInteracted };
}
