export default function Tick() {
  return (
    <span className="tick" aria-hidden="true">
      <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="3.4"
      >
        <path
          d="M4 12.5 10 18.5 20 6"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    </span>
  );
}
