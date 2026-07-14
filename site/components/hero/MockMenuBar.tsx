import DropGlyph from "@/components/ui/DropGlyph";
import { MiniRing } from "./MiniRing";

/** The desktop menu bar: the Dropper droplet (or upload ring), plus decorative
    wifi / battery / clock, mirroring the app's status item. */
export function MockMenuBar({ uploadingPct }: { uploadingPct: number | null }) {
  return (
    <div className="mock-menubar">
      <span className="mb-app" aria-hidden="true">
        {uploadingPct === null ? (
          <DropGlyph color="var(--accent-bright)" />
        ) : (
          <MiniRing pct={uploadingPct} />
        )}
      </span>
      <svg
        className="mb-icon"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        aria-hidden="true"
      >
        <path
          d="M2 9.5C7.5 4.5 16.5 4.5 22 9.5M5.5 13c3.8-3.4 9.2-3.4 13 0M9 16.5c1.8-1.6 4.2-1.6 6 0M12 20h.01"
          strokeLinecap="round"
        />
      </svg>
      <svg
        className="mb-icon"
        viewBox="0 0 28 14"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.6"
        aria-hidden="true"
      >
        <rect x="1" y="1.5" width="22" height="11" rx="3" />
        <rect
          x="3"
          y="3.5"
          width="14"
          height="7"
          rx="1.5"
          fill="currentColor"
          stroke="none"
        />
        <path d="M25 5v4" strokeLinecap="round" />
      </svg>
      <span>Fri 9:41 AM</span>
    </div>
  );
}
