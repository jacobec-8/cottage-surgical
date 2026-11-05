// Where each "Shop by category" tile sits in the carousel. Slot 0 is the picked
// tile in the middle; negative slots are to its left, positive to its right.
// The ring loops, so the tile after the last one is the first.

/** Slots this far from the middle are drawn; the rest are hidden off stage. */
export const SHOWN_REACH = 2
/** Horizontal drag, in px, that counts as a swipe rather than a tap. */
export const SWIPE_MIN_PX = 40
/** How long each tile rests in the middle before the ring turns on its own. */
export const AUTO_ADVANCE_MS = 3500

export function wrapIndex(index: number, count: number): number {
  return ((index % count) + count) % count
}

export function slotOf(index: number, active: number, count: number): number {
  const ahead = wrapIndex(index - active, count)
  return ahead > count / 2 ? ahead - count : ahead
}

export function isShown(slot: number): boolean {
  return Math.abs(slot) <= SHOWN_REACH
}

/**
 * True when moving from `from` to `to` sends this tile around the back of the
 * ring (e.g. far right to far left). That tile should jump, not slide across.
 */
export function jumpsAcross(index: number, from: number, to: number, count: number): boolean {
  return Math.abs(slotOf(index, to, count) - slotOf(index, from, count)) > Math.floor(count / 2)
}

/** +1 for a swipe left (next tile), -1 for a swipe right, 0 for a tap. */
export function swipeStep(dx: number): number {
  if (Math.abs(dx) < SWIPE_MIN_PX) return 0
  return dx < 0 ? 1 : -1
}
