/**
 * The split drop target shown while dragging over an existing share
 * (PopoverViews.swift, linksContainer): left half adds to the selected
 * collection, right half starts a new share.
 */
export default function SplitDropMockup() {
  return (
    <div className="panel" style={{ borderRadius: 12, padding: 12 }}>
      <div className="mock-split">
        <span className="zone active">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <rect x="3" y="8" width="13" height="12" rx="2" />
            <path d="M7 8V6a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-1" />
            <path d="M9.5 14h6M12.5 11v6" strokeLinecap="round" />
          </svg>
          Add to collection
        </span>
        <span className="zone">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M6 2h9l5 5v15H6z" strokeLinejoin="round" />
            <path d="M12 9v7M9 13.5 12 16.5l3-3" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
          Upload new item
        </span>
      </div>
    </div>
  );
}
