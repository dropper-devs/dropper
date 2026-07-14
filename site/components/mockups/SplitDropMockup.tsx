import { AddToCollectionIcon, NewShareIcon } from "@/components/ui/icons";

/**
 * The split drop target shown while dragging over an existing share
 * (PopoverViews.swift, linksContainer): left half adds to the selected
 * collection, right half starts a new share.
 */
export default function SplitDropMockup() {
  return (
    <div className="panel" style={{ borderRadius: 12, padding: 12 }}>
      <div className="mock-split">
        <span className="zone is-active">
          <AddToCollectionIcon />
          Add to collection
        </span>
        <span className="zone">
          <NewShareIcon />
          Upload new item
        </span>
      </div>
    </div>
  );
}
