import type { RefObject } from "react";
import { DEMO_FILES, linksFor } from "@/components/demo/data";
import type { Phase, RowID } from "@/components/demo/data";
import { icons } from "@/components/demo/icons";
import { CopyLinkButton } from "./CopyLinkButton";
import type { Copied, CopyWhich } from "./CopyLinkButton";
import type { ZoneHandlers } from "./useTouchDrag";

/**
 * The drop strip: one fixed footprint shared by all three states — idle/
 * targeted "Drop file here", the upload progress ring, and the resulting
 * links panel. Sizing is constant so no state ever shifts the layout.
 */
export function DropStrip({
  dropZoneRef,
  zoneHandlers,
  chipsReachedApex,
  phase,
  copied,
  onCopy,
}: {
  dropZoneRef: RefObject<HTMLDivElement | null>;
  zoneHandlers: ZoneHandlers;
  chipsReachedApex: boolean;
  phase: Phase;
  copied: Copied;
  onCopy: (which: CopyWhich, row: RowID) => void;
}) {
  return (
    <div
      ref={dropZoneRef}
      className={`mock-strip-area${chipsReachedApex ? " intro-glow" : ""}`}
      {...zoneHandlers}
      aria-live="polite"
    >
      {phase.t === "uploading" ? (
        <div className="mock-uploading">
          <span className="ringbtn" title="Cancel upload">
            <svg viewBox="0 0 32 32" aria-hidden="true">
              <circle className="track" cx="16" cy="16" r="14" />
              <circle
                className="bar"
                cx="16"
                cy="16"
                r="14"
                strokeDasharray={2 * Math.PI * 14}
                strokeDashoffset={2 * Math.PI * 14 * (1 - phase.pct)}
              />
              <path className="xm" d="M12.5 12.5l7 7M19.5 12.5l-7 7" />
            </svg>
          </span>
          <span className="mock-upinfo">
            <span className="upname">{DEMO_FILES[phase.kind].file}</span>
            <span className="uppct">{Math.round(phase.pct * 100)}%</span>
          </span>
        </div>
      ) : phase.t === "links" ? (
        <div className="mock-links">
          <span className="name">{linksFor(phase.row).name}</span>
          <a
            className="mock-link-btn"
            href={linksFor(phase.row).page}
            target="_blank"
            rel="noopener"
          >
            {icons.globe} Open web page
          </a>
          <CopyLinkButton
            which="page"
            row={phase.row}
            label="Copy page link"
            copied={copied}
            onCopy={onCopy}
          />
          {linksFor(phase.row).file ? (
            <CopyLinkButton
              which="file"
              row={phase.row}
              label="Copy file link"
              copied={copied}
              onCopy={onCopy}
            />
          ) : null}
        </div>
      ) : (
        <div
          className={`mock-strip${phase.t === "targeted" ? " is-active" : ""}`}
        >
          <span className="strip-icon">{icons.dropDoc}</span>
          Drop file here
        </div>
      )}
    </div>
  );
}
