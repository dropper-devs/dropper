"use client";

/**
 * Interactive hero demo: a working recreation of the Dropper dropdown at the
 * app's real size (380×575), floating over a desktop wallpaper.
 *
 * The panel is a functional emulation of ShareListView.swift/ShareStore.swift
 * (path bar excepted — static). This module is just the composition: the row
 * model lives in {@link useListState}, the drag-and-drop in {@link useTouchDrag},
 * the confirm grace period in {@link useConfirmRevert}, the scroll-spring/bob
 * physics in {@link useChipFloat}, and the drag-me nudge in {@link useWiggleNudge}.
 * Each visible region is its own presentational component (MockMenuBar,
 * MockToolbar, MockPathBar, ListRow, DropStrip, ChipArc/Chip).
 *
 * Everything lives inside a fixed-size panel: the list area is reserved up
 * front and the strip states share one footprint, so no state — uploads,
 * archive view, empty state, confirm pairs — ever shifts the hero's layout.
 */

import { useEffect, useRef, useState } from "react";
import {
  KINDS,
  rowBytes,
  linksFor,
  humanSize,
  writeClipboard,
} from "@/components/demo/data";
import type { Kind, RowID, Phase } from "@/components/demo/data";
import { icons } from "@/components/demo/icons";
import { analytics } from "@/lib/analytics";

import {
  UPLOAD_DURATION_MS,
  COPY_FEEDBACK_MS,
  REFRESH_SPIN_MS,
} from "./constants";
import { useListState } from "./useListState";
import { useConfirmRevert } from "./useConfirmRevert";
import { useChipFloat } from "./useChipFloat";
import { useWiggleNudge } from "./useWiggleNudge";
import { useTouchDrag } from "./useTouchDrag";
import { ChipArc } from "./ChipArc";
import { Chip } from "./Chip";
import { MockMenuBar } from "./MockMenuBar";
import { MockToolbar } from "./MockToolbar";
import { MockPathBar } from "./MockPathBar";
import { ListRow } from "./ListRow";
import { DropStrip } from "./DropStrip";
import type { Copied, CopyWhich } from "./CopyLinkButton";

export default function HeroDemo() {
  const [phase, setPhase] = useState<Phase>({ t: "idle" });
  const [list, dispatch] = useListState();
  const [showingArchive, setShowingArchive] = useState(false);
  const [spinning, setSpinning] = useState(false);
  const [copied, setCopied] = useState<Copied>(null);

  const { confirming, openConfirm, closeConfirm, cancelRevert, armRevert } =
    useConfirmRevert();
  const { wiggle, markInteracted } = useWiggleNudge();

  const arcRef = useRef<HTMLDivElement>(null);
  const dropZoneRef = useRef<HTMLDivElement>(null);
  const busyRef = useRef(false);
  const rafRef = useRef(0);
  const refreshTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const copyTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const chipsReachedApex = useChipFloat(arcRef);
  const dnd = useTouchDrag({
    dropZoneRef,
    setPhase,
    onDropKind: addKind,
    onInteract: markInteracted,
  });

  useEffect(
    () => () => {
      cancelAnimationFrame(rafRef.current);
      if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
      if (copyTimerRef.current) clearTimeout(copyTimerRef.current);
    },
    [],
  );

  /** Strip falls back to idle if the row it points at leaves the list. */
  const clearPhaseIf = (ids: RowID[]) => {
    setPhase((p) =>
      p.t === "links" && ids.includes(p.row) ? { t: "idle" } : p,
    );
  };

  /** View switches clear selection and pending confirms, like the app. */
  const setView = (archiveView: boolean) => {
    setShowingArchive(archiveView);
    setPhase((p) => (p.t === "uploading" ? p : { t: "idle" }));
    closeConfirm();
    dispatch({ type: "clearSelection" });
  };

  /* ------------------------------ list actions ------------------------- */

  const visible = list.rows.filter(
    (id) => list.archived.includes(id) === showingArchive,
  );
  const allSelected =
    visible.length > 0 && visible.every((id) => list.selected.includes(id));

  function toggleSelect(id: RowID) {
    dispatch({ type: "toggleSelect", id });
  }

  function masterClick() {
    dispatch({ type: "masterSelect", visible, allSelected });
  }

  function deleteRows(ids: RowID[]) {
    closeConfirm();
    clearPhaseIf(ids);
    dispatch({ type: "deleteRows", ids });
  }

  function archiveRows(ids: RowID[], archive: boolean) {
    clearPhaseIf(ids);
    dispatch({ type: "archiveRows", ids, archive });
  }

  function refreshClick() {
    setSpinning(true);
    if (refreshTimerRef.current) clearTimeout(refreshTimerRef.current);
    refreshTimerRef.current = setTimeout(() => {
      refreshTimerRef.current = null;
      setSpinning(false);
    }, REFRESH_SPIN_MS);
  }

  /* ------------------------------ chip flow ----------------------------- */

  function addKind(kind: Kind) {
    if (busyRef.current) return;
    setCopied(null);
    if (list.rows.includes(kind)) {
      // Present (maybe archived): re-select, never duplicate. Reveal the
      // archive view if that's where the row lives.
      const isArchived = list.archived.includes(kind);
      if (isArchived !== showingArchive) setView(isArchived);
      setPhase({ t: "links", row: kind });
      return;
    }
    busyRef.current = true;
    analytics.track("Demo File Dropped", { kind });
    setPhase({ t: "uploading", kind, pct: 0 });
    const t0 = performance.now();
    const tick = (now: number) => {
      const raw = Math.min(1, (now - t0) / UPLOAD_DURATION_MS);
      const eased = 1 - Math.pow(1 - raw, 2.2);
      setPhase({ t: "uploading", kind, pct: eased });
      if (raw < 1) {
        rafRef.current = requestAnimationFrame(tick);
      } else {
        dispatch({ type: "addRow", kind });
        setView(false); // new uploads land in the main list (app: finish())
        setPhase({ t: "links", row: kind });
        busyRef.current = false;
      }
    };
    rafRef.current = requestAnimationFrame(tick);
  }

  function tapChip(kind: Kind) {
    if (dnd.consumeSuppressedTap()) return;
    markInteracted();
    if (busyRef.current) return;
    addKind(kind); // the chip stays put; the panel shows the upload
  }

  async function copyLink(which: CopyWhich, row: RowID) {
    const links = linksFor(row);
    const path = which === "page" ? links.page : links.file;
    if (!path) return;
    const ok = await writeClipboard(
      new URL(path, window.location.href).toString(),
    );
    setCopied({ row, which, ok });
    if (copyTimerRef.current) clearTimeout(copyTimerRef.current);
    copyTimerRef.current = setTimeout(() => {
      copyTimerRef.current = null;
      setCopied(null);
    }, COPY_FEEDBACK_MS);
  }

  /** Row content click — the app's onTapGesture: highlight + links state,
      or deselect when the row is already highlighted. */
  function rowClick(id: RowID) {
    setPhase((p) => {
      if (p.t === "uploading") return p;
      if (p.t === "links" && p.row === id) return { t: "idle" };
      return { t: "links", row: id };
    });
  }

  /* ------------------------------- derived ------------------------------ */

  const highlighted = phase.t === "links" ? phase.row : null;
  const mainRows = list.rows.filter((id) => !list.archived.includes(id));
  const mainBytes = mainRows.reduce((s, id) => s + rowBytes(id), 0);
  const archivedCount = list.archived.length;
  const summary =
    `${humanSize(mainBytes)} · ${mainRows.length} item${mainRows.length === 1 ? "" : "s"}` +
    (archivedCount > 0 ? ` · ${archivedCount} archived` : "");
  const uploadingPct = phase.t === "uploading" ? phase.pct : null;
  const masterIcon =
    list.selected.length === 0
      ? icons.square
      : allSelected
        ? icons.checkSquareFill
        : icons.minusSquareFill;

  const renderChip = (k: Kind, arc: boolean) => (
    <Chip
      key={k}
      kind={k}
      arc={arc}
      wiggle={wiggle}
      dragHandlers={dnd.chipHandlers(k)}
      onTap={() => tapChip(k)}
    />
  );

  return (
    <div className="hero-demo">
      {/* Desktop: chips scattered along an arc in the hero's negative space.
          Anchored to the demo so their relationship cannot drift; hidden under 1180px
          where the plain .chip-row below the mock takes over. */}
      <ChipArc arcRef={arcRef} chipsReachedApex={chipsReachedApex}>
        {KINDS.map((k) => renderChip(k, true))}
      </ChipArc>

      {/* the "screen": wallpaper, menu bar, floating dropdown */}
      <div className="mock-screen">
        <MockMenuBar uploadingPct={uploadingPct} />

        <div className="mock-desktop">
          <div className="mock-dropdown panel">
            <MockToolbar
              masterIcon={masterIcon}
              masterDisabled={visible.length === 0}
              onMasterClick={masterClick}
              allSelected={allSelected}
              showingArchive={showingArchive}
              selectedCount={list.selected.length}
              onArchiveSelected={() =>
                archiveRows(list.selected, !showingArchive)
              }
              confirmingBulk={confirming === "bulk"}
              onBulkDeleteAsk={() => openConfirm("bulk")}
              onBulkDeleteConfirm={() => deleteRows(list.selected)}
              onConfirmCancel={closeConfirm}
              onConfirmPairEnter={cancelRevert}
              onConfirmPairLeave={armRevert}
              onToggleArchiveView={() => setView(!showingArchive)}
              spinning={spinning}
              onRefresh={refreshClick}
            />

            <MockPathBar />

            {/* row list — fixed-height area; main or archive view */}
            <div className="mock-list">
              {visible.length === 0 ? (
                <div className="mock-empty">
                  {showingArchive ? icons.archive : icons.tray}
                  {showingArchive
                    ? "Nothing archived."
                    : "Empty folder.\nDrop files below."}
                </div>
              ) : (
                visible.map((id) => (
                  <ListRow
                    key={id}
                    id={id}
                    inArchive={showingArchive}
                    selected={list.selected.includes(id)}
                    highlighted={id === highlighted}
                    confirming={confirming === id}
                    entering={id !== "seed"}
                    onSelect={() => toggleSelect(id)}
                    onArchive={() => archiveRows([id], !showingArchive)}
                    onDeleteAsk={() => openConfirm(id)}
                    onDeleteConfirm={() => deleteRows([id])}
                    onDeleteCancel={closeConfirm}
                    onPairEnter={cancelRevert}
                    onPairLeave={armRevert}
                    onRowClick={() => rowClick(id)}
                  />
                ))
              )}
            </div>

            <DropStrip
              dropZoneRef={dropZoneRef}
              zoneHandlers={dnd.zoneHandlers}
              chipsReachedApex={chipsReachedApex}
              phase={phase}
              copied={copied}
              onCopy={copyLink}
            />

            {/* footer — live bucket summary */}
            <div className="mock-footer">{summary}</div>
          </div>
        </div>
      </div>

      {/* narrow-screen fallback: the plain chip row (arc hidden by CSS) */}
      <div className="chip-row" role="group" aria-label="Demo files to drop">
        {KINDS.map((k) => renderChip(k, false))}
      </div>
      <p className="chip-hint">
        Live demo — drag a file onto the drop zone, or just tap one. The whole
        panel works: click a row for its links, select, archive, delete.
      </p>
    </div>
  );
}
