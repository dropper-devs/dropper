import { useEffect, useRef, useState } from "react";
import type { RowID } from "@/components/demo/data";
import { REVERT_MS } from "./constants";

export type ConfirmTarget = RowID | "bulk" | null;

/**
 * The delete confirm-pair's grace period (app: ~1s revert after hover-away).
 * `openConfirm` shows the ✓/✕ pair; leaving the pair `armRevert`s the timer,
 * re-entering `cancelRevert`s it, and `closeConfirm` dismisses immediately.
 */
export function useConfirmRevert() {
  const [confirming, setConfirming] = useState<ConfirmTarget>(null);
  const revertRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const cancelRevert = () => {
    if (revertRef.current) clearTimeout(revertRef.current);
    revertRef.current = null;
  };
  const armRevert = () => {
    cancelRevert();
    revertRef.current = setTimeout(() => setConfirming(null), REVERT_MS);
  };
  const openConfirm = (id: RowID | "bulk") => {
    cancelRevert();
    setConfirming(id);
  };
  const closeConfirm = () => {
    setConfirming(null);
    cancelRevert();
  };

  useEffect(() => cancelRevert, []);

  return { confirming, openConfirm, closeConfirm, cancelRevert, armRevert };
}
