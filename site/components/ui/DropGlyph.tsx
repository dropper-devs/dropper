/** The Dropper droplet mark. The path is the single source of truth for the
    glyph, reused by the hero demo's menu-bar icon. */
export default function DropGlyph({
  size = 22,
  color = "var(--accent)",
}: {
  size?: number;
  color?: string;
}) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="currentColor"
      style={{ color }}
      aria-hidden="true"
    >
      <path d="M12 2.7c3.6 4.4 6.3 8 6.3 11.4a6.3 6.3 0 1 1-12.6 0C5.7 10.7 8.4 7.1 12 2.7z" />
    </svg>
  );
}
