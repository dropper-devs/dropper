"use client"

/**
 * Interactive hero demo: a working recreation of the Dropper dropdown at the
 * app's real size (380×575), floating over a desktop wallpaper.
 *
 * The panel is a functional emulation of ShareListView.swift/ShareStore.swift
 * (path bar excepted — static):
 *  - row + master checkboxes with the app's square / minus.square.fill /
 *    checkmark.square.fill states and an "N selected" caption
 *  - trash → inline ✕/✓ confirm pair with the app's ~1s hover-away revert;
 *    per-row circle-X → inline ✓/✕ pair, same grace period
 *  - archive-selected + per-row archive (instant, non-destructive), archive
 *    view toggle (accent when active), unarchive from the archive view
 *  - live footer arithmetic ("<size> · N items · M archived") and the app's
 *    real empty states ("Empty folder. / Drop files below.", "Nothing
 *    archived.")
 *
 * Chips: drag onto the strip or tap. New kinds run the simulated upload
 * (progress ring, then links state); kinds already present re-select their
 * row instead (jumping to the archive view if that's where the row lives).
 * Deleting a row clears its guard so its chip genuinely re-uploads.
 *
 * Everything lives inside a fixed-size panel: the list area is reserved up
 * front and the strip states share one footprint, so no state — uploads,
 * archive view, empty state, confirm pairs — ever shifts the hero's layout.
 */

import { useEffect, useRef, useState } from "react"
import {
  KINDS,
  DEMO_FILES,
  SEED,
  rowTitle,
  rowMeta,
  rowBytes,
  linksFor,
  humanSize,
  writeClipboard,
} from "./demo/data"
import type { Kind, RowID, Phase, ListState } from "./demo/data"
import { icons, kindIcon, chipLabel } from "./demo/icons"
import { arcChipStyle, arrowLinePath, arrowHeadPath, ENTER_FROM } from "./demo/geometry"
import { analytics } from "@/lib/analytics"

/* -------------------------------- component ------------------------------ */

export default function HeroDemo() {
  const [phase, setPhase] = useState<Phase>({ t: "idle" })
  const [list, setList] = useState<ListState>({
    rows: ["seed"],
    archived: [],
    selected: [],
  })
  const [showingArchive, setShowingArchive] = useState(false)
  const [confirming, setConfirming] = useState<RowID | "bulk" | null>(null)
  const [spinning, setSpinning] = useState(false)
  const [copied, setCopied] = useState<{ which: "page" | "file"; ok: boolean } | null>(null)
  // Nudge animation: the movie chip wiggles periodically until the visitor
  // engages with any chip (drag or tap), then never again.
  const [wiggle, setWiggle] = useState(false)
  const interactedRef = useRef(false)

  const listRef = useRef(list)
  // Touch dragging (HTML5 drag-and-drop does not exist on touch devices):
  // the chip follows the finger via CSS translate; releasing over the drop
  // zone uploads it. A completed drag suppresses the synthetic click that
  // follows, so it can't double-trigger.
  const touchDragRef = useRef<{
    kind: Kind
    el: HTMLElement
    startX: number
    startY: number
    active: boolean
  } | null>(null)
  const suppressTapRef = useRef(false)
  const busyRef = useRef(false)
  const rafRef = useRef(0)
  const dragDepth = useRef(0)
  const revertRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const timersRef = useRef<ReturnType<typeof setTimeout>[]>([])

  useEffect(
    () => () => {
      cancelAnimationFrame(rafRef.current)
      timersRef.current.forEach(clearTimeout)
      if (revertRef.current) clearTimeout(revertRef.current)
    },
    [],
  )

  /* Floating cards: each chip trails page scroll on its own underdamped
     spring — it drifts after the page moves and settles with a small
     natural bounce, so the arc feels physically detached. Written to the
     --float-y variable that every chip transform (rest, launch, wiggle)
     already includes. */
  useEffect(() => {
    const chips = Array.from(document.querySelectorAll<HTMLElement>(".chip-arc .chip"))
    if (chips.length === 0) return
    const DRIFT = [0.2, 0.26, 0.17, 0.23] // fraction of scroll each chip lags
    const STIFF = [90, 68, 112, 78] // spring stiffness; varied = organic
    const RATIO = 0.55 // damping ratio < 1 → slight overshoot
    // Idle undulation: a slow per-chip sine rides on top of the spring, so
    // the cards gently bob even when the page is static. Distinct periods
    // and phases keep them from ever moving in lockstep.
    const BOB_AMP = [3.5, 4.5, 3, 5] // px
    const BOB_PERIOD = [6.5, 8.2, 5.6, 7.3] // seconds per cycle
    const BOB_PHASE = [0, 2.1, 4.4, 1.2]
    // Entrance: chips are server-rendered ENTER_FROM px below rest; start
    // the spring from there so they visibly rise into place on load.
    const pos = KINDS.map((k) => ENTER_FROM[k])
    const vel = chips.map(() => 0)
    let raf = 0
    let last = performance.now()
    const tick = (now: number) => {
      const dt = Math.min(0.048, (now - last) / 1000)
      last = now
      const t = now / 1000
      chips.forEach((el, i) => {
        const target = window.scrollY * DRIFT[i]
        const k = STIFF[i]
        const c = 2 * Math.sqrt(k) * RATIO
        vel[i] += ((target - pos[i]) * k - vel[i] * c) * dt
        pos[i] += vel[i] * dt
        const bob = BOB_AMP[i] * Math.sin((2 * Math.PI * t) / BOB_PERIOD[i] + BOB_PHASE[i])
        el.style.setProperty("--float-y", `${(pos[i] + bob).toFixed(2)}px`)
      })
      // never stops: the bob runs whenever the tab is visible (rAF pauses
      // itself in background tabs)
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => {
      cancelAnimationFrame(raf)
    }
  }, [])

  useEffect(() => {
    const nudge = () => {
      if (interactedRef.current) return
      setWiggle(true)
      setTimeout(() => setWiggle(false), 700)
    }
    const first = setTimeout(nudge, 2000)
    const repeat = setInterval(nudge, 10000)
    return () => {
      clearTimeout(first)
      clearInterval(repeat)
    }
  }, [])

  const later = (fn: () => void, ms: number) => {
    timersRef.current.push(setTimeout(fn, ms))
  }

  const setListSync = (updater: (l: ListState) => ListState) => {
    setList((l) => {
      const next = updater(l)
      listRef.current = next
      return next
    })
  }

  /* ---- confirm-pair grace period (app: ~1s revert after hover-away) ---- */
  const cancelRevert = () => {
    if (revertRef.current) clearTimeout(revertRef.current)
    revertRef.current = null
  }
  const armRevert = () => {
    cancelRevert()
    revertRef.current = setTimeout(() => setConfirming(null), 1000)
  }
  const openConfirm = (id: RowID | "bulk") => {
    cancelRevert()
    setConfirming(id)
  }

  /** Strip falls back to idle if the row it points at leaves the list. */
  const clearPhaseIf = (ids: RowID[]) => {
    setPhase((p) => (p.t === "links" && ids.includes(p.row) ? { t: "idle" } : p))
  }

  /** View switches clear selection and pending confirms, like the app. */
  const setView = (archiveView: boolean) => {
    setShowingArchive(archiveView)
    setConfirming(null)
    cancelRevert()
    setListSync((l) => ({ ...l, selected: [] }))
  }

  /* ------------------------------ list actions ------------------------- */

  const visible = list.rows.filter((id) => list.archived.includes(id) === showingArchive)
  const allSelected = visible.length > 0 && visible.every((id) => list.selected.includes(id))

  function toggleSelect(id: RowID) {
    setListSync((l) => ({
      ...l,
      selected: l.selected.includes(id) ? l.selected.filter((s) => s !== id) : [...l.selected, id],
    }))
  }

  function masterClick() {
    setListSync((l) => ({ ...l, selected: allSelected ? [] : visible }))
  }

  function deleteRows(ids: RowID[]) {
    setConfirming(null)
    cancelRevert()
    clearPhaseIf(ids)
    setListSync((l) => ({
      rows: l.rows.filter((r) => !ids.includes(r)),
      archived: l.archived.filter((r) => !ids.includes(r)),
      selected: l.selected.filter((r) => !ids.includes(r)),
    }))
  }

  function archiveRows(ids: RowID[], archive: boolean) {
    if (archive) clearPhaseIf(ids)
    setListSync((l) => ({
      ...l,
      archived: archive
        ? [...l.archived, ...ids.filter((r) => !l.archived.includes(r))]
        : l.archived.filter((r) => !ids.includes(r)),
      selected: l.selected.filter((r) => !ids.includes(r)),
    }))
  }

  function refreshClick() {
    setSpinning(true)
    later(() => setSpinning(false), 650)
  }

  /* ------------------------------ chip flow ----------------------------- */

  function addKind(kind: Kind) {
    if (busyRef.current) return
    setCopied(null)
    const l = listRef.current
    if (l.rows.includes(kind)) {
      // Present (maybe archived): re-select, never duplicate. Reveal the
      // archive view if that's where the row lives.
      const isArchived = l.archived.includes(kind)
      if (isArchived !== showingArchive) setView(isArchived)
      setPhase({ t: "links", row: kind })
      return
    }
    busyRef.current = true
    analytics.track("Demo File Dropped", { kind })
    setPhase({ t: "uploading", kind, pct: 0 })
    const t0 = performance.now()
    const duration = 1500
    const tick = (now: number) => {
      const raw = Math.min(1, (now - t0) / duration)
      const eased = 1 - Math.pow(1 - raw, 2.2)
      setPhase({ t: "uploading", kind, pct: eased })
      if (raw < 1) {
        rafRef.current = requestAnimationFrame(tick)
      } else {
        setListSync((l2) => ({ ...l2, rows: [...l2.rows, kind] }))
        setView(false) // new uploads land in the main list (app: finish())
        setPhase({ t: "links", row: kind })
        busyRef.current = false
      }
    }
    rafRef.current = requestAnimationFrame(tick)
  }

  function tapChip(kind: Kind) {
    if (suppressTapRef.current) {
      suppressTapRef.current = false
      return
    }
    interactedRef.current = true
    setWiggle(false)
    if (busyRef.current) return
    addKind(kind) // the chip stays put; the panel shows the upload
  }

  /* ------------------------------ drag & drop --------------------------- */

  function overDropZone(x: number, y: number): boolean {
    const zone = document.querySelector(".mock-strip-area")
    if (!zone) return false
    const r = zone.getBoundingClientRect()
    return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom
  }

  function onChipPointerDown(kind: Kind) {
    return (e: React.PointerEvent<HTMLButtonElement>) => {
      if (e.pointerType !== "touch") return
      const el = e.currentTarget as HTMLElement
      el.setPointerCapture(e.pointerId)
      touchDragRef.current = {
        kind, el, startX: e.clientX, startY: e.clientY, active: false,
      }
    }
  }

  function onChipPointerMove(e: React.PointerEvent<HTMLButtonElement>) {
    const drag = touchDragRef.current
    if (!drag) return
    const dx = e.clientX - drag.startX
    const dy = e.clientY - drag.startY
    if (!drag.active) {
      if (Math.hypot(dx, dy) < 8) return
      drag.active = true
      interactedRef.current = true
      setWiggle(false)
      drag.el.classList.add("touch-dragging")
    }
    drag.el.style.translate = `${dx}px ${dy}px`
    const over = overDropZone(e.clientX, e.clientY)
    setPhase((p) => {
      if (p.t === "uploading") return p
      if (over) return { t: "targeted" }
      return p.t === "targeted" ? { t: "idle" } : p
    })
  }

  function onChipPointerEnd(e: React.PointerEvent<HTMLButtonElement>) {
    const drag = touchDragRef.current
    if (!drag) return
    touchDragRef.current = null
    drag.el.classList.remove("touch-dragging")
    drag.el.style.translate = ""
    if (!drag.active) return // plain tap: the click event handles it
    suppressTapRef.current = true
    if (e.type !== "pointercancel" && overDropZone(e.clientX, e.clientY)) {
      addKind(drag.kind)
    } else {
      setPhase((p) => (p.t === "targeted" ? { t: "idle" } : p))
    }
  }

  function setDragPreview(e: React.DragEvent<HTMLButtonElement>) {
    const source = e.currentTarget
    const fromArc = source.closest(".chip-arc") !== null
    const host = document.createElement("div")
    const preview = source.cloneNode(true) as HTMLButtonElement

    host.className = fromArc ? "chip-arc" : "chip-row"
    host.setAttribute("aria-hidden", "true")
    Object.assign(host.style, {
      display: fromArc ? "block" : "flex",
      position: "fixed",
      top: "0",
      left: "0",
      right: "auto",
      width: `${source.offsetWidth}px`,
      height: `${source.offsetHeight}px`,
      margin: "0",
      transform: "none",
      pointerEvents: "none",
      zIndex: "2147483647",
    })

    preview.removeAttribute("draggable")
    preview.classList.remove("wiggle")
    preview.tabIndex = -1
    Object.assign(preview.style, {
      position: "relative",
      inset: "auto",
      top: "0",
      left: "0",
      margin: "0",
      transform: "none",
      animation: "none",
      transition: "none",
      pointerEvents: "none",
    })

    host.appendChild(preview)
    document.body.appendChild(host)
    e.dataTransfer.setDragImage(
      preview,
      Math.round(source.offsetWidth / 2),
      Math.round(source.offsetHeight / 2),
    )
    requestAnimationFrame(() => host.remove())
  }

  function onDragStart(kind: Kind) {
    return (e: React.DragEvent<HTMLButtonElement>) => {
      interactedRef.current = true
      setWiggle(false)
      e.dataTransfer.setData("text/plain", kind)
      e.dataTransfer.effectAllowed = "copy"
      setDragPreview(e)
    }
  }
  function onZoneDragEnter(e: React.DragEvent) {
    e.preventDefault()
    dragDepth.current++
    setPhase((p) => (p.t === "uploading" ? p : { t: "targeted" }))
  }
  function onZoneDragOver(e: React.DragEvent) {
    e.preventDefault()
    e.dataTransfer.dropEffect = "copy"
  }
  function onZoneDragLeave() {
    dragDepth.current = Math.max(0, dragDepth.current - 1)
    if (dragDepth.current === 0) {
      setPhase((p) => (p.t === "targeted" ? { t: "idle" } : p))
    }
  }
  function onZoneDrop(e: React.DragEvent) {
    e.preventDefault()
    dragDepth.current = 0
    const kind = e.dataTransfer.getData("text/plain") as Kind
    if (KINDS.includes(kind)) {
      addKind(kind)
    } else {
      setPhase((p) => (p.t === "targeted" ? { t: "idle" } : p))
    }
  }

  async function copyLink(which: "page" | "file", row: RowID) {
    const links = linksFor(row)
    const path = which === "page" ? links.page : links.file
    if (!path) return
    const ok = await writeClipboard(new URL(path, window.location.href).toString())
    setCopied({ which, ok })
    later(() => setCopied(null), 1200)
  }

  /** Row content click — the app's onTapGesture: highlight + links state,
      or deselect when the row is already highlighted. */
  function rowClick(id: RowID) {
    setPhase((p) => {
      if (p.t === "uploading") return p
      if (p.t === "links" && p.row === id) return { t: "idle" }
      return { t: "links", row: id }
    })
  }

  /* ------------------------------- derived ------------------------------ */

  const highlighted = phase.t === "links" ? phase.row : null
  const mainRows = list.rows.filter((id) => !list.archived.includes(id))
  const mainBytes = mainRows.reduce((s, id) => s + rowBytes(id), 0)
  const archivedCount = list.archived.length
  const summary =
    `${humanSize(mainBytes)} · ${mainRows.length} item${mainRows.length === 1 ? "" : "s"}` +
    (archivedCount > 0 ? ` · ${archivedCount} archived` : "")
  const uploadingPct = phase.t === "uploading" ? phase.pct : null
  const masterIcon =
    list.selected.length === 0 ? icons.square : allSelected ? icons.checkSquareFill : icons.minusSquareFill

  const renderChip = (k: Kind, arc: boolean) => (
    <button
      key={k}
      type="button"
      className={`chip${k === "movie" && wiggle ? " wiggle" : ""}`}
      style={arc ? arcChipStyle(k) : undefined}
      draggable
      onDragStart={onDragStart(k)}
      onPointerDown={onChipPointerDown(k)}
      onPointerMove={onChipPointerMove}
      onPointerUp={onChipPointerEnd}
      onPointerCancel={onChipPointerEnd}
      onClick={() => tapChip(k)}
      aria-label={`Upload the demo ${k} file`}
    >
      <span className="chip-icon">{kindIcon[k]}</span>
      <span className="chip-kind">{chipLabel[k]}</span>
      <span className="chip-size">{DEMO_FILES[k].sizeLabel}</span>
    </button>
  )

  return (
    <div className="hero-demo">
      {/* Desktop: chips scattered along an arc in the hero's negative space.
          Anchored to the demo so their relationship cannot drift; hidden under 1180px
          where the plain .chip-row below the mock takes over. */}
      <div className="chip-arc" role="group" aria-label="Demo files to drop">
        <svg className="chip-arc-arrow" viewBox="0 0 1100 637" preserveAspectRatio="none" aria-hidden="true">
          <path className="chip-arc-arrow-line" d={arrowLinePath()} />
          <path className="chip-arc-arrow-head" d={arrowHeadPath()} />
        </svg>
        {KINDS.map((k) => renderChip(k, true))}
      </div>

      {/* the "screen": wallpaper, menu bar, floating dropdown */}
      <div className="mock-screen">
        <div className="mock-menubar">
          <span className="mb-app" aria-hidden="true">
            {uploadingPct === null ? (
              <svg viewBox="0 0 24 24" fill="currentColor">
                <path d="M12 2.7c3.6 4.4 6.3 8 6.3 11.4a6.3 6.3 0 1 1-12.6 0C5.7 10.7 8.4 7.1 12 2.7z" />
              </svg>
            ) : (
              <MiniRing pct={uploadingPct} />
            )}
          </span>
          <svg
            className="mb-icon"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            aria-hidden="true"
          >
            <path
              d="M2 9.5C7.5 4.5 16.5 4.5 22 9.5M5.5 13c3.8-3.4 9.2-3.4 13 0M9 16.5c1.8-1.6 4.2-1.6 6 0M12 20h.01"
              strokeLinecap="round"
            />
          </svg>
          <svg
            className="mb-icon"
            viewBox="0 0 28 14"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.6"
            aria-hidden="true"
          >
            <rect x="1" y="1.5" width="22" height="11" rx="3" />
            <rect x="3" y="3.5" width="14" height="7" rx="1.5" fill="currentColor" stroke="none" />
            <path d="M25 5v4" strokeLinecap="round" />
          </svg>
          <span>Fri 9:41 AM</span>
        </div>

        <div className="mock-desktop">
          <div className="mock-dropdown panel">
            {/* toolbar — ShareListView.toolbar (gear removed by request) */}
            <div className="mock-toolbar">
              <button
                type="button"
                className="mock-tbtn"
                aria-label="Select all"
                disabled={visible.length === 0}
                onClick={masterClick}
              >
                {masterIcon}
              </button>

              {confirming === "bulk" ? (
                <span className="confirm-pair" onMouseEnter={cancelRevert} onMouseLeave={armRevert}>
                  <button
                    type="button"
                    className="mock-tbtn no"
                    aria-label="Cancel delete"
                    onClick={() => {
                      setConfirming(null)
                      cancelRevert()
                    }}
                  >
                    {icons.x}
                  </button>
                  <button
                    type="button"
                    className="mock-tbtn ok"
                    aria-label="Confirm delete selected"
                    onClick={() => deleteRows(list.selected)}
                  >
                    {icons.check}
                  </button>
                </span>
              ) : (
                <button
                  type="button"
                  className="mock-tbtn"
                  aria-label="Delete selected"
                  disabled={list.selected.length === 0}
                  onClick={() => openConfirm("bulk")}
                >
                  {icons.trash}
                </button>
              )}

              <button
                type="button"
                className="mock-tbtn"
                aria-label={showingArchive ? "Unarchive selected" : "Archive selected"}
                disabled={list.selected.length === 0}
                onClick={() => archiveRows(list.selected, !showingArchive)}
              >
                {showingArchive ? icons.trayUp : icons.archive}
              </button>

              {list.selected.length > 0 ? <span className="selcount">{list.selected.length} selected</span> : null}

              <span className="mock-tspacer" />

              <button
                type="button"
                className={`mock-tbtn${showingArchive ? " acc" : ""}`}
                aria-label={showingArchive ? "Back to the list" : "Show archive"}
                onClick={() => setView(!showingArchive)}
              >
                {icons.archive}
              </button>
              <button
                type="button"
                className={`mock-tbtn${spinning ? " spinning" : ""}`}
                aria-label="Refresh"
                onClick={refreshClick}
              >
                {icons.refresh}
              </button>
              <button type="button" className="mock-tbtn" aria-label="Close">
                {icons.x}
              </button>
            </div>

            {/* path bar — static by design */}
            <div className="mock-pathbar" aria-hidden="true">
              <span className="mock-ticon">{icons.house}</span>
              <span className="mock-crumb-sep">{icons.chevron}</span>
              <span className="mock-crumb">client-work</span>
              <span className="mock-tspacer" />
              <span className="mock-ticon">{icons.arrowUp}</span>
              <span className="mock-ticon">{icons.folderPlus}</span>
            </div>

            {/* row list — fixed-height area; main or archive view */}
            <div className="mock-list">
              {visible.length === 0 ? (
                <div className="mock-empty">
                  {showingArchive ? icons.archive : icons.tray}
                  {showingArchive ? "Nothing archived." : "Empty folder.\nDrop files below."}
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
                    onDeleteCancel={() => {
                      setConfirming(null)
                      cancelRevert()
                    }}
                    onPairEnter={cancelRevert}
                    onPairLeave={armRevert}
                    onRowClick={() => rowClick(id)}
                  />
                ))
              )}
            </div>

            {/* drop strip — one fixed footprint for all three states */}
            <div
              className="mock-strip-area"
              onDragEnter={onZoneDragEnter}
              onDragOver={onZoneDragOver}
              onDragLeave={onZoneDragLeave}
              onDrop={onZoneDrop}
              aria-live="polite"
            >
              {phase.t === "uploading" ? (
                <div className="mock-uploading">
                  <span className="ringbtn" title="Cancel upload">
                    <svg viewBox="0 0 32 32" aria-hidden="true">
                      <circle className="track" cx="16" cy="16" r="14" />
                      <circle
                        className="bar"
                        cx="16"
                        cy="16"
                        r="14"
                        strokeDasharray={2 * Math.PI * 14}
                        strokeDashoffset={2 * Math.PI * 14 * (1 - phase.pct)}
                      />
                      <path className="xm" d="M12.5 12.5l7 7M19.5 12.5l-7 7" />
                    </svg>
                  </span>
                  <span className="mock-upinfo">
                    <span className="upname">{DEMO_FILES[phase.kind].file}</span>
                    <span className="uppct">{Math.round(phase.pct * 100)}%</span>
                  </span>
                </div>
              ) : phase.t === "links" ? (
                <div className="mock-links">
                  <span className="name">{linksFor(phase.row).name}</span>
                  <a className="mock-link-btn" href={linksFor(phase.row).page} target="_blank" rel="noopener">
                    {icons.globe} Open web page
                  </a>
                  <button
                    type="button"
                    className={`mock-link-btn${copied?.which === "page" ? " copied" : ""}`}
                    onClick={() => copyLink("page", phase.row)}
                  >
                    {copied?.which === "page" ? icons.check : icons.copy}
                    {copied?.which === "page" ? (copied.ok ? "Copied ✓" : "Copy failed") : "Copy page link"}
                  </button>
                  {linksFor(phase.row).file ? (
                    <button
                      type="button"
                      className={`mock-link-btn${copied?.which === "file" ? " copied" : ""}`}
                      onClick={() => copyLink("file", phase.row)}
                    >
                      {copied?.which === "file" ? icons.check : icons.copy}
                      {copied?.which === "file" ? (copied.ok ? "Copied ✓" : "Copy failed") : "Copy file link"}
                    </button>
                  ) : null}
                </div>
              ) : (
                <div className={`mock-strip${phase.t === "targeted" ? " active" : ""}`}>
                  <span className="strip-icon">{icons.dropDoc}</span>
                  Drop file here
                </div>
              )}
            </div>

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
        Live demo — drag a file onto the drop zone, or just tap one. The whole panel works: click a row for its links,
        select, archive, delete.
      </p>
    </div>
  )
}

/* ------------------------------- subviews -------------------------------- */

function MiniRing({ pct }: { pct: number }) {
  const r = 6.5
  const c = 2 * Math.PI * r
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <circle cx="8" cy="8" r={r} fill="none" stroke="rgba(255,255,255,0.25)" strokeWidth="2" />
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
  )
}

function ListRow({
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
  id: RowID
  inArchive: boolean
  selected: boolean
  highlighted: boolean
  confirming: boolean
  entering: boolean
  onSelect: () => void
  onArchive: () => void
  onDeleteAsk: () => void
  onDeleteConfirm: () => void
  onDeleteCancel: () => void
  onPairEnter: () => void
  onPairLeave: () => void
  onRowClick: () => void
}) {
  return (
    <div className={`mock-lrow${highlighted ? " hl" : ""}${entering ? " enter" : ""}`}>
      <button
        type="button"
        className={`ric${selected ? " on" : ""}`}
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
        aria-label={inArchive ? `Unarchive ${rowTitle(id)}` : `Archive ${rowTitle(id)}`}
        onClick={onArchive}
      >
        {inArchive ? icons.trayUp : icons.archive}
      </button>
      {confirming ? (
        <span className="confirm-pair" onMouseEnter={onPairEnter} onMouseLeave={onPairLeave}>
          <button
            type="button"
            className="mock-tbtn ok"
            aria-label={`Confirm delete ${rowTitle(id)}`}
            onClick={onDeleteConfirm}
          >
            {icons.check}
          </button>
          <button type="button" className="mock-tbtn no" aria-label="Cancel delete" onClick={onDeleteCancel}>
            {icons.x}
          </button>
        </span>
      ) : (
        <button type="button" className="ric" aria-label={`Delete ${rowTitle(id)}`} onClick={onDeleteAsk}>
          {icons.xCircle}
        </button>
      )}
    </div>
  )
}
