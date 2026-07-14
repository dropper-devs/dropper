import { icons } from "@/components/demo/icons";
import type { RowID } from "@/components/demo/data";

export type CopyWhich = "page" | "file";
export type Copied = { row: RowID; which: CopyWhich; ok: boolean } | null;

/** A "Copy page link" / "Copy file link" button. Collapses the copy-state
    check (`copied?.row === row && copied.which === which`) that the two
    near-identical buttons repeated. */
export function CopyLinkButton({
  which,
  row,
  label,
  copied,
  onCopy,
}: {
  which: CopyWhich;
  row: RowID;
  label: string;
  copied: Copied;
  onCopy: (which: CopyWhich, row: RowID) => void;
}) {
  const isCopied = copied?.row === row && copied.which === which;
  return (
    <button
      type="button"
      className={`mock-link-btn${isCopied ? " copied" : ""}`}
      onClick={() => onCopy(which, row)}
    >
      {isCopied ? icons.check : icons.copy}
      {isCopied ? (copied.ok ? "Copied ✓" : "Copy failed") : label}
    </button>
  );
}
