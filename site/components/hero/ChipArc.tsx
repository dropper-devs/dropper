import type { ReactNode, RefObject } from "react";
import { arrowLinePath, arrowHeadPath } from "@/components/demo/geometry";

/**
 * The desktop chip arc: the dashed bezier that sweeps toward the drop zone
 * (drawn on with a mask once the chips settle) with the floating chips laid
 * over it. Anchored to the hero grid; hidden under 1180px by CSS.
 */
export function ChipArc({
  arcRef,
  chipsReachedApex,
  children,
}: {
  arcRef: RefObject<HTMLDivElement | null>;
  chipsReachedApex: boolean;
  children: ReactNode;
}) {
  return (
    <div
      ref={arcRef}
      className={`chip-arc${chipsReachedApex ? " chips-reached-apex" : ""}`}
      role="group"
      aria-label="Demo files to drop"
    >
      <svg
        className="chip-arc-arrow"
        viewBox="0 0 1100 637"
        preserveAspectRatio="none"
        aria-hidden="true"
      >
        <defs>
          <mask
            id="chip-arc-arrow-reveal"
            x="0"
            y="0"
            width="1100"
            height="637"
            maskUnits="userSpaceOnUse"
          >
            <path
              className="chip-arc-arrow-reveal"
              d={arrowLinePath()}
              pathLength={1}
            />
          </mask>
        </defs>
        <path
          className="chip-arc-arrow-line"
          d={arrowLinePath()}
          mask="url(#chip-arc-arrow-reveal)"
        />
        <path className="chip-arc-arrow-head" d={arrowHeadPath()} />
      </svg>
      {children}
    </div>
  );
}
