import { DEMO_FILES } from "@/components/demo/data";
import type { Kind } from "@/components/demo/data";
import { kindIcon, chipLabel } from "@/components/demo/icons";
import { arcChipStyle } from "@/components/demo/geometry";
import type { ChipDragHandlers } from "./useTouchDrag";

/** A draggable demo-file chip. Rendered twice: positioned along the arc
    (`arc`) on desktop, and in the plain fallback row on narrow screens. */
export function Chip({
  kind,
  arc,
  wiggle,
  dragHandlers,
  onTap,
}: {
  kind: Kind;
  arc: boolean;
  wiggle: boolean;
  dragHandlers: ChipDragHandlers;
  onTap: () => void;
}) {
  return (
    <button
      type="button"
      className={`chip${kind === "movie" && wiggle ? " wiggle" : ""}`}
      style={arc ? arcChipStyle(kind) : undefined}
      data-kind={kind}
      {...dragHandlers}
      onClick={onTap}
      aria-label={`Upload the demo ${kind} file`}
    >
      <span className="chip-icon">{kindIcon[kind]}</span>
      <span className="chip-kind">{chipLabel[kind]}</span>
      <span className="chip-size">{DEMO_FILES[kind].sizeLabel}</span>
    </button>
  );
}
