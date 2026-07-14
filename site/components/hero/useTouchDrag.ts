import { useRef } from "react";
import type React from "react";
import { KINDS } from "@/components/demo/data";
import type { Kind, Phase } from "@/components/demo/data";

const TOUCH_DRAG_THRESHOLD = 8; // px of travel before a touch press becomes a drag

/**
 * The chip drag-and-drop, both transports:
 *  - HTML5 drag (mouse): a cloned drag image, plus the four drop-zone events.
 *  - Pointer/touch drag: HTML5 DnD does not exist on touch, so the chip
 *    follows the finger via CSS `translate`; releasing over the zone uploads
 *    it, and the trailing synthetic click is suppressed so it can't re-fire.
 *
 * Targeting (the strip's `targeted` glow) is driven through `setPhase`; a drop
 * calls `onDropKind`; the first real interaction calls `onInteract` (which
 * cancels the wiggle nudge).
 */
export function useTouchDrag({
  dropZoneRef,
  setPhase,
  onDropKind,
  onInteract,
}: {
  dropZoneRef: React.RefObject<HTMLDivElement | null>;
  setPhase: React.Dispatch<React.SetStateAction<Phase>>;
  onDropKind: (kind: Kind) => void;
  onInteract: () => void;
}) {
  const touchDragRef = useRef<{
    kind: Kind;
    el: HTMLElement;
    startX: number;
    startY: number;
    active: boolean;
  } | null>(null);
  const suppressTapRef = useRef(false);
  const dragDepth = useRef(0);

  function overDropZone(x: number, y: number): boolean {
    const zone = dropZoneRef.current;
    if (!zone) return false;
    const r = zone.getBoundingClientRect();
    return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
  }

  const clearTargeted = () =>
    setPhase((p) => (p.t === "targeted" ? { t: "idle" } : p));

  /* ------------------------------ touch drag ------------------------------ */

  function onChipPointerDown(kind: Kind) {
    return (e: React.PointerEvent<HTMLButtonElement>) => {
      if (e.pointerType !== "touch") return;
      const el = e.currentTarget as HTMLElement;
      el.setPointerCapture(e.pointerId);
      touchDragRef.current = {
        kind,
        el,
        startX: e.clientX,
        startY: e.clientY,
        active: false,
      };
    };
  }

  function onChipPointerMove(e: React.PointerEvent<HTMLButtonElement>) {
    const drag = touchDragRef.current;
    if (!drag) return;
    const dx = e.clientX - drag.startX;
    const dy = e.clientY - drag.startY;
    if (!drag.active) {
      if (Math.hypot(dx, dy) < TOUCH_DRAG_THRESHOLD) return;
      drag.active = true;
      onInteract();
      drag.el.classList.add("touch-dragging");
    }
    drag.el.style.translate = `${dx}px ${dy}px`;
    const over = overDropZone(e.clientX, e.clientY);
    setPhase((p) => {
      if (p.t === "uploading") return p;
      if (over) return { t: "targeted" };
      return p.t === "targeted" ? { t: "idle" } : p;
    });
  }

  function onChipPointerEnd(e: React.PointerEvent<HTMLButtonElement>) {
    const drag = touchDragRef.current;
    if (!drag) return;
    touchDragRef.current = null;
    drag.el.classList.remove("touch-dragging");
    drag.el.style.translate = "";
    if (!drag.active) return; // plain tap: the click event handles it
    suppressTapRef.current = true;
    if (e.type !== "pointercancel" && overDropZone(e.clientX, e.clientY)) {
      onDropKind(drag.kind);
    } else {
      clearTargeted();
    }
  }

  /* ------------------------------ html5 drag ------------------------------ */

  function setDragPreview(e: React.DragEvent<HTMLButtonElement>) {
    const source = e.currentTarget;
    const fromArc = source.closest(".chip-arc") !== null;
    const host = document.createElement("div");
    const preview = source.cloneNode(true) as HTMLButtonElement;

    host.className = fromArc ? "chip-arc" : "chip-row";
    host.setAttribute("aria-hidden", "true");
    Object.assign(host.style, {
      display: fromArc ? "block" : "flex",
      position: "fixed",
      top: "0",
      left: "0",
      right: "auto",
      width: `${source.offsetWidth}px`,
      height: `${source.offsetHeight}px`,
      margin: "0",
      transform: "none",
      pointerEvents: "none",
      zIndex: "2147483647",
    });

    preview.removeAttribute("draggable");
    preview.classList.remove("wiggle");
    preview.tabIndex = -1;
    Object.assign(preview.style, {
      position: "relative",
      inset: "auto",
      top: "0",
      left: "0",
      margin: "0",
      transform: "none",
      animation: "none",
      transition: "none",
      pointerEvents: "none",
    });

    host.appendChild(preview);
    document.body.appendChild(host);
    e.dataTransfer.setDragImage(
      preview,
      Math.round(source.offsetWidth / 2),
      Math.round(source.offsetHeight / 2),
    );
    requestAnimationFrame(() => host.remove());
  }

  function onDragStart(kind: Kind) {
    return (e: React.DragEvent<HTMLButtonElement>) => {
      onInteract();
      e.dataTransfer.setData("text/plain", kind);
      e.dataTransfer.effectAllowed = "copy";
      setDragPreview(e);
    };
  }

  function onZoneDragEnter(e: React.DragEvent) {
    e.preventDefault();
    dragDepth.current++;
    setPhase((p) => (p.t === "uploading" ? p : { t: "targeted" }));
  }
  function onZoneDragOver(e: React.DragEvent) {
    e.preventDefault();
    e.dataTransfer.dropEffect = "copy";
  }
  function onZoneDragLeave() {
    dragDepth.current = Math.max(0, dragDepth.current - 1);
    if (dragDepth.current === 0) clearTargeted();
  }
  function onZoneDrop(e: React.DragEvent) {
    e.preventDefault();
    dragDepth.current = 0;
    const kind = e.dataTransfer.getData("text/plain") as Kind;
    if (KINDS.includes(kind)) {
      onDropKind(kind);
    } else {
      clearTargeted();
    }
  }

  return {
    /** Drag/press props for a single chip button. */
    chipHandlers: (kind: Kind) => ({
      draggable: true,
      onDragStart: onDragStart(kind),
      onPointerDown: onChipPointerDown(kind),
      onPointerMove: onChipPointerMove,
      onPointerUp: onChipPointerEnd,
      onPointerCancel: onChipPointerEnd,
    }),
    /** Drop-zone props for the strip area. */
    zoneHandlers: {
      onDragEnter: onZoneDragEnter,
      onDragOver: onZoneDragOver,
      onDragLeave: onZoneDragLeave,
      onDrop: onZoneDrop,
    },
    /** True once (and clears) if the last pointer sequence was a drag, so the
        trailing synthetic click can be ignored. */
    consumeSuppressedTap: () => {
      if (suppressTapRef.current) {
        suppressTapRef.current = false;
        return true;
      }
      return false;
    },
  };
}

export type ChipDragHandlers = ReturnType<
  ReturnType<typeof useTouchDrag>["chipHandlers"]
>;
export type ZoneHandlers = ReturnType<typeof useTouchDrag>["zoneHandlers"];
