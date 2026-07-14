import { rowTitle, rowMeta } from "@/components/demo/data";
import type { RowID } from "@/components/demo/data";
import { icons, kindIcon } from "@/components/demo/icons";

/** One share row: select control, thumbnail, tap-for-links content, archive
    toggle, and delete (which swaps to an inline ✓/✕ confirm pair). */
export function ListRow({
  id,
  inArchive,
  selected,
  highlighted,
  confirming,
  entering,
  onSelect,
  onArchive,
  onDeleteAsk,
  onDeleteConfirm,
  onDeleteCancel,
  onPairEnter,
  onPairLeave,
  onRowClick,
}: {
  id: RowID;
  inArchive: boolean;
  selected: boolean;
  highlighted: boolean;
  confirming: boolean;
  entering: boolean;
  onSelect: () => void;
  onArchive: () => void;
  onDeleteAsk: () => void;
  onDeleteConfirm: () => void;
  onDeleteCancel: () => void;
  onPairEnter: () => void;
  onPairLeave: () => void;
  onRowClick: () => void;
}) {
  return (
    <div
      className={`mock-lrow${highlighted ? " hl" : ""}${entering ? " enter" : ""}`}
    >
      <button
        type="button"
        className={`ric select-control${selected ? " on" : ""}`}
        aria-label={`Select ${rowTitle(id)}`}
        aria-pressed={selected}
        onClick={onSelect}
      >
        {selected ? icons.checkSquareFill : icons.square}
      </button>
      <span className="thumb30">{kindIcon[id]}</span>
      {/* the app's row onTapGesture: content click toggles links state */}
      <button
        type="button"
        className="rinfo"
        aria-label={`Show links for ${rowTitle(id)}`}
        aria-pressed={highlighted}
        onClick={onRowClick}
      >
        <span className="rtitle">{rowTitle(id)}</span>
        <span className="rmeta">{rowMeta(id)}</span>
      </button>
      <button
        type="button"
        className="ric"
        aria-label={
          inArchive ? `Unarchive ${rowTitle(id)}` : `Archive ${rowTitle(id)}`
        }
        onClick={onArchive}
      >
        {inArchive ? icons.trayUp : icons.archive}
      </button>
      {confirming ? (
        <span
          className="confirm-pair"
          onMouseEnter={onPairEnter}
          onMouseLeave={onPairLeave}
        >
          <button
            type="button"
            className="mock-tbtn ok"
            aria-label={`Confirm delete ${rowTitle(id)}`}
            onClick={onDeleteConfirm}
          >
            {icons.check}
          </button>
          <button
            type="button"
            className="mock-tbtn no"
            aria-label="Cancel delete"
            onClick={onDeleteCancel}
          >
            {icons.x}
          </button>
        </span>
      ) : (
        <button
          type="button"
          className="ric"
          aria-label={`Delete ${rowTitle(id)}`}
          onClick={onDeleteAsk}
        >
          {icons.trash}
        </button>
      )}
    </div>
  );
}
