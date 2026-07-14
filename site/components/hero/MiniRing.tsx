/** The menu-bar upload progress ring (replaces the droplet mid-upload). */
export function MiniRing({ pct }: { pct: number }) {
  const r = 6.5;
  const c = 2 * Math.PI * r;
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <circle
        cx="8"
        cy="8"
        r={r}
        fill="none"
        stroke="rgba(255,255,255,0.25)"
        strokeWidth="2"
      />
      <circle
        cx="8"
        cy="8"
        r={r}
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeDasharray={c}
        strokeDashoffset={c * (1 - pct)}
        transform="rotate(-90 8 8)"
      />
    </svg>
  );
}
