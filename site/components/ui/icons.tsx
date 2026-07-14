/**
 * Shared site icon set. Section components stay declarative — the raw SVG
 * markup lives here and is rendered in the same CSS context as before
 * (feature-card icon slots, wizard controls, buttons), so sizing and stroke
 * still come from the surrounding stylesheet exactly as they did inline.
 */

/* -- feature-card glyphs (viewBox 24, currentColor stroke, sized by CSS) -- */

export function DropIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path
        d="M12 3v10m-4-4 4 4 4-4"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M4 16v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3"
        strokeLinecap="round"
      />
    </svg>
  );
}

export function UploadCloudIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path
        d="M7 17.5a4.5 4.5 0 1 1 .9-8.9 5.5 5.5 0 0 1 10.6 1.5 3.7 3.7 0 0 1-.9 7.3"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <path
        d="M12 21v-8m-3.5 3.5L12 13l3.5 3.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export function PasteIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path
        d="M9 4H7a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2h-2"
        strokeLinejoin="round"
      />
      <rect x="9" y="2.5" width="6" height="3.5" rx="1" />
      <path d="M9 11.5h6M9 15.5h4" strokeLinecap="round" />
    </svg>
  );
}

export function ArchiveBoxIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <rect x="3" y="4" width="18" height="5" rx="1.5" />
      <path
        d="M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9M10 13h4"
        strokeLinecap="round"
      />
    </svg>
  );
}

export function StarIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path
        d="M12 3l2.7 5.7 6.3.8-4.6 4.3 1.2 6.2L12 17l-5.6 3 1.2-6.2L3 9.5l6.3-.8z"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export function FolderIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
    </svg>
  );
}

/* -- split drop-target zones (SplitDropMockup) -- */

export function AddToCollectionIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <rect x="3" y="8" width="13" height="12" rx="2" />
      <path d="M7 8V6a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-1" />
      <path d="M9.5 14h6M12.5 11v6" strokeLinecap="round" />
    </svg>
  );
}

export function NewShareIcon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M6 2h9l5 5v15H6z" strokeLinejoin="round" />
      <path
        d="M12 9v7M9 13.5 12 16.5l3-3"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/* -- download button -- */

export function DownloadIcon() {
  return (
    <svg
      width="15"
      height="15"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.4"
      aria-hidden="true"
    >
      <path
        d="M12 3v12M6.5 10 12 15.5 17.5 10M4 20h16"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/* -- setup wizard controls -- */

export function WizardArrow({ direction }: { direction: "left" | "right" }) {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true">
      <path
        d={
          direction === "left"
            ? "M12.5 4.5 7 10l5.5 5.5"
            : "m7.5 4.5 5.5 5.5-5.5 5.5"
        }
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export function BenefitIcon({ kind }: { kind: "clock" | "check" | "lock" }) {
  return (
    <span aria-hidden="true">
      <svg viewBox="0 0 20 20">
        {kind === "clock" && (
          <>
            <circle cx="10" cy="10" r="6.5" />
            <path d="M10 6.5v3.8l2.5 1.5" />
          </>
        )}
        {kind === "check" && <path d="m5.5 10.2 2.7 2.7 6.2-6.2" />}
        {kind === "lock" && (
          <>
            <rect x="5.5" y="8.5" width="9" height="6.8" rx="1.6" />
            <path d="M7.4 8.5V6.9a2.6 2.6 0 0 1 5.2 0v1.6" />
          </>
        )}
      </svg>
    </span>
  );
}
