import type { ReactNode } from "react";
import { icons } from "@/components/demo/icons";

/** The dropdown toolbar (ShareListView.toolbar): master select, archive
    selected, delete-with-confirm-pair, the "N selected" caption, plus the
    archive-view toggle, refresh and close. */
export function MockToolbar({
  masterIcon,
  masterDisabled,
  onMasterClick,
  allSelected,
  showingArchive,
  selectedCount,
  onArchiveSelected,
  confirmingBulk,
  onBulkDeleteAsk,
  onBulkDeleteConfirm,
  onConfirmCancel,
  onConfirmPairEnter,
  onConfirmPairLeave,
  onToggleArchiveView,
  spinning,
  onRefresh,
}: {
  masterIcon: ReactNode;
  masterDisabled: boolean;
  onMasterClick: () => void;
  allSelected: boolean;
  showingArchive: boolean;
  selectedCount: number;
  onArchiveSelected: () => void;
  confirmingBulk: boolean;
  onBulkDeleteAsk: () => void;
  onBulkDeleteConfirm: () => void;
  onConfirmCancel: () => void;
  onConfirmPairEnter: () => void;
  onConfirmPairLeave: () => void;
  onToggleArchiveView: () => void;
  spinning: boolean;
  onRefresh: () => void;
}) {
  return (
    <div className="mock-toolbar">
      <button
        type="button"
        className="mock-tbtn"
        aria-label={allSelected ? "Deselect all" : "Select all"}
        disabled={masterDisabled}
        onClick={onMasterClick}
      >
        {masterIcon}
      </button>

      <button
        type="button"
        className="mock-tbtn"
        aria-label={showingArchive ? "Unarchive selected" : "Archive selected"}
        disabled={selectedCount === 0}
        onClick={onArchiveSelected}
      >
        {showingArchive ? icons.trayUp : icons.archive}
      </button>

      {confirmingBulk ? (
        <span
          className="confirm-pair"
          onMouseEnter={onConfirmPairEnter}
          onMouseLeave={onConfirmPairLeave}
        >
          <button
            type="button"
            className="mock-tbtn no"
            aria-label="Cancel delete"
            onClick={onConfirmCancel}
          >
            {icons.x}
          </button>
          <button
            type="button"
            className="mock-tbtn ok"
            aria-label="Confirm delete selected"
            onClick={onBulkDeleteConfirm}
          >
            {icons.check}
          </button>
        </span>
      ) : (
        <button
          type="button"
          className="mock-tbtn"
          aria-label="Delete selected"
          disabled={selectedCount === 0}
          onClick={onBulkDeleteAsk}
        >
          {icons.trash}
        </button>
      )}

      {selectedCount > 0 ? (
        <span className="selcount">{selectedCount} selected</span>
      ) : null}

      <span className="mock-tspacer" />

      <button
        type="button"
        className={`mock-tbtn${showingArchive ? " acc" : ""}`}
        aria-label={showingArchive ? "Back to the list" : "Show archive"}
        onClick={onToggleArchiveView}
      >
        {icons.archive}
      </button>
      <button
        type="button"
        className={`mock-tbtn${spinning ? " spinning" : ""}`}
        aria-label="Refresh"
        onClick={onRefresh}
      >
        {icons.refresh}
      </button>
      <button type="button" className="mock-tbtn" aria-label="Close">
        {icons.x}
      </button>
    </div>
  );
}
