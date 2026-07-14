import type { CSSProperties } from "react"
import type { Kind } from "./data"

/* --------------------- hero arc composition (desktop) -------------------- */
/* Chips float in the hero's negative space along a gentle arc from the
   upper-left down toward the gap before the mock screen; a dashed bezier
   passes behind them and gestures at the drop zone. Coordinates live in a 0-100 viewBox
   stretched over the hero grid (non-scaling strokes keep lines crisp), so
   chips and arrow endpoints stay glued together at any width. */

/* ---- chip knobs: the chips ride the arrow's curve -----------------------
   CHIP_T    — each chip's spot along the dashed line: 0 = the line's
               start, 1 = the arrowhead. Chip centers AND rotations are
               computed from the ARROW bezier below (each chip lies along
               the curve's direction at its spot), so they stay glued to
               the curve no matter how you reshape it. Defaults are evenly
               spaced by arc length.
   CHIP_TILT — optional extra degrees ADDED to each chip's curve-following
               rotation (0 = exactly along the curve) */
export const CHIP_T: Record<Kind, number> = {
  image: 0.75,
  audio: 0.3,
  movie: 0.58,
  markdown: 0.075,
}
export const CHIP_TILT: Record<Kind, number> = {
  image: 0,
  audio: 0,
  movie: 0,
  markdown: 0,
}

/** Point on the arrow's cubic bezier at t (0..1). */
function arrowPoint(t: number): { x: number; y: number } {
  const { start, c1, c2, end } = arrowCtrl()
  const u = 1 - t
  const w0 = u * u * u
  const w1 = 3 * u * u * t
  const w2 = 3 * u * t * t
  const w3 = t * t * t
  return {
    x: w0 * start.x + w1 * c1.x + w2 * c2.x + w3 * end.x,
    y: w0 * start.y + w1 * c1.y + w2 * c2.y + w3 * end.y,
  }
}

/** Direction of the curve at t, in degrees (0 = rightward, + = clockwise). */
function arrowTangentDeg(t: number): number {
  const { start, c1, c2, end } = arrowCtrl()
  const u = 1 - t
  const dx = 3 * u * u * (c1.x - start.x) + 6 * u * t * (c2.x - c1.x) + 3 * t * t * (end.x - c2.x)
  const dy = 3 * u * u * (c1.y - start.y) + 6 * u * t * (c2.y - c1.y) + 3 * t * t * (end.y - c2.y)
  return (Math.atan2(dy, dx) * 180) / Math.PI
}

/* Where each chip starts on first paint, px below its resting spot — the
   float spring carries it up into place (the "entrance"). Server-rendered
   into the inline style so there is no flash at the resting position. */
export const ENTER_FROM: Record<Kind, number> = {
  image: 150,
  audio: 210,
  movie: 120,
  markdown: 180,
}

/* Per-chip float personality for HeroDemo's scroll spring + idle bob:
   drift     — fraction of page scroll the chip lags behind
   stiff     — spring stiffness; varied = organic
   bobAmp    — idle undulation amplitude, px
   bobPeriod — seconds per bob cycle
   bobPhase  — phase offset
   Distinct stiffnesses, periods and phases keep the cards from ever
   moving in lockstep. */
export const FLOAT: Record<
  Kind,
  { drift: number; stiff: number; bobAmp: number; bobPeriod: number; bobPhase: number }
> = {
  image: { drift: 0.2, stiff: 90, bobAmp: 3.5, bobPeriod: 6.5, bobPhase: 0 },
  audio: { drift: 0.26, stiff: 68, bobAmp: 4.5, bobPeriod: 8.2, bobPhase: 2.1 },
  movie: { drift: 0.17, stiff: 112, bobAmp: 3, bobPeriod: 5.6, bobPhase: 4.4 },
  markdown: { drift: 0.23, stiff: 78, bobAmp: 5, bobPeriod: 7.3, bobPhase: 1.2 },
}

export function arcChipStyle(kind: Kind): CSSProperties {
  const t = CHIP_T[kind]
  const p = arrowPoint(t)
  const rot = arrowTangentDeg(t) + CHIP_TILT[kind]
  return {
    left: `${(p.x - 37).toFixed(1)}px`, // 37/44.5 center the 74×89 chip
    top: `${(p.y - 44.5).toFixed(1)}px`,
    "--rot": `${rot.toFixed(1)}deg`,
    "--float-y": `${ENTER_FROM[kind]}px`,
  } as CSSProperties
}

/* ---- arrow knobs: the dashed line, px in the same 1100×637 layer --------
   One cubic bezier: starts at START, gets pulled toward C1 then C2 (the
   curve never touches the control points, they just bend it), lands on
   END. The arrowhead is generated at END automatically, aimed along the
   curve's final direction (C2 → END), so it always points the right way. */
export const ARROW = {
  start: { x: 300, y: 220 },
  c1: { x: 450.8, y: 5.7 },
  c2: { x: 802.2, y: -36.9 },
  end: { x: 780.2, y: 610 },
  headSize: 15, // barb length, px
  /* The radius knob: scales how far the curve bows away from the straight
     start→end line. 1 = exactly as drawn above, <1 flattens it out
     (bigger radius), >1 bows it harder (tighter radius), 0 = straight.
     Chips and arrowhead follow, since everything derives from the curve. */
  bend: 0.75,
}

/** Effective bezier control points after the bend knob. */
function arrowCtrl() {
  const { start, c1, c2, end, bend } = ARROW
  const lerp = (a: { x: number; y: number }, b: { x: number; y: number }, t: number) => ({
    x: a.x + (b.x - a.x) * t,
    y: a.y + (b.y - a.y) * t,
  })
  const b1 = lerp(start, end, 1 / 3)
  const b2 = lerp(start, end, 2 / 3)
  return {
    start,
    end,
    c1: lerp(b1, c1, bend),
    c2: lerp(b2, c2, bend),
  }
}

export function arrowLinePath(): string {
  const { start, c1, c2, end } = arrowCtrl()
  return `M ${start.x} ${start.y} C ${c1.x} ${c1.y} ${c2.x} ${c2.y} ${end.x} ${end.y}`
}

export function arrowHeadPath(): string {
  const { c2, end } = arrowCtrl()
  const { headSize } = ARROW
  const angle = Math.atan2(end.y - c2.y, end.x - c2.x)
  const barb = (side: number) => {
    const a = angle + Math.PI + (side * Math.PI) / 6 // 30° barbs
    return `${(end.x + headSize * Math.cos(a)).toFixed(1)} ${(end.y + headSize * Math.sin(a)).toFixed(1)}`
  }
  return `M ${barb(-1)} L ${end.x} ${end.y} L ${barb(1)}`
}
