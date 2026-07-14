import type React from "react";
import type { Kind, RowID } from "./data";

/* ----------------------------- inline icons ------------------------------ */
/* SF-symbol-style strokes matching the app's toolbar/rows. */

const I = ({ d, className }: { d: React.ReactNode; className?: string }) => (
  <svg
    className={className}
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
  >
    {d}
  </svg>
);

export const icons = {
  square: <I d={<rect x="4" y="4" width="16" height="16" rx="3" />} />,
  checkSquareFill: (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <rect x="3.5" y="3.5" width="17" height="17" rx="4" fill="currentColor" />
      <path
        d="M8 12.4 11 15.4 16.5 9"
        fill="none"
        style={{ stroke: "var(--accent-ink)" }}
        strokeWidth="2.4"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  ),
  minusSquareFill: (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <rect x="3.5" y="3.5" width="17" height="17" rx="4" fill="currentColor" />
      <path
        d="M8 12h8"
        fill="none"
        style={{ stroke: "var(--accent-ink)" }}
        strokeWidth="2.4"
        strokeLinecap="round"
      />
    </svg>
  ),
  trash: (
    <I
      className="icon-trash"
      d={
        <>
          <path d="M4 7h16M9.5 7V4.5h5V7M6.5 7l1 13h9l1-13M10 11v5M14 11v5" />
        </>
      }
    />
  ),
  archive: (
    <I
      d={
        <>
          <rect x="3" y="4" width="18" height="5" rx="1" />
          <path d="M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9M10 13h4" />
        </>
      }
    />
  ),
  tray: (
    <I
      d={
        <>
          <path d="M3 13.5h4.8l1.7 2.5h5l1.7-2.5H21" />
          <path d="M21 13.5V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4.5M3 13.5 5.5 6h13L21 13.5" />
        </>
      }
    />
  ),
  trayUp: (
    <I
      d={
        <>
          <path d="M3 14h4.8l1.7 2.5h5l1.7-2.5H21" />
          <path d="M21 14v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
          <path d="M12 10.5V3M8.8 6.2 12 3l3.2 3.2" />
        </>
      }
    />
  ),
  refresh: (
    <I
      d={
        <>
          <path d="M20 12a8 8 0 1 1-2.3-5.6" />
          <path d="M20 3v4h-4" />
        </>
      }
    />
  ),
  x: <I d={<path d="M6 6l12 12M18 6 6 18" />} />,
  check: <I d={<path d="M4.5 12.5 10 18 19.5 6.5" />} />,
  house: (
    <I
      d={
        <>
          <path d="M4 11 12 4l8 7" />
          <path d="M6 10v9h12v-9" />
        </>
      }
    />
  ),
  chevron: <I d={<path d="M9.5 5.5 16 12l-6.5 6.5" />} />,
  arrowUp: <I d={<path d="M12 20V5M6 10.5 12 4.5l6 6" />} />,
  folderPlus: (
    <I
      d={
        <>
          <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
          <path d="M12 11v5M9.5 13.5h5" />
        </>
      }
    />
  ),
  photo: (
    <I
      d={
        <>
          <rect x="3" y="5" width="18" height="14" rx="2" />
          <circle cx="8.5" cy="10" r="1.4" />
          <path d="m5.5 17 4.5-4.5 3 3 2.5-2.5 3 4" />
        </>
      }
    />
  ),
  film: (
    <I
      d={
        <>
          <rect x="3" y="4" width="18" height="16" rx="2" />
          <path d="M7 4v16M17 4v16M3 9h4M3 15h4M17 9h4M17 15h4" />
        </>
      }
    />
  ),
  waveform: <I d={<path d="M3 12h1.5M7 8.5v7M11 5v14M15 8v8M19 10.5v3" />} />,
  docText: (
    <I
      d={
        <>
          <path d="M6 2h9l5 5v15H6z" />
          <path d="M15 2v5h5" />
          <path d="M9.5 12h5M9.5 15.5h5M9.5 19h3" />
        </>
      }
    />
  ),
  dropDoc: (
    <I
      d={
        <>
          <path d="M6 2h9l5 5v15H6z" />
          <path d="M12 9v7M9 13.5l3 3 3-3" />
        </>
      }
    />
  ),
  globe: (
    <I
      d={
        <>
          <circle cx="12" cy="12" r="9" />
          <path d="M3 12h18M12 3c2.5 2.6 3.8 5.7 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.7-3.8-9S9.5 5.6 12 3z" />
        </>
      }
    />
  ),
  copy: (
    <I
      d={
        <>
          <rect x="9" y="9" width="11" height="11" rx="2" />
          <path d="M5 15V5a2 2 0 0 1 2-2h10" />
        </>
      }
    />
  ),
};

export const kindIcon: Record<RowID, React.ReactNode> = {
  seed: icons.photo,
  image: icons.photo,
  movie: icons.film,
  audio: icons.waveform,
  markdown: icons.docText,
};

export const chipLabel: Record<Kind, string> = {
  image: "IMAGE",
  audio: "AUDIO",
  movie: "MOVIE",
  markdown: "MD",
};
