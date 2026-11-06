// The hero's background reel: three clips that play in turn behind the text.
// Each clip file is the animation on a larger canvas filled with the clip's own
// background colour: half its width spare on each side, 1.25x its height above and
// half below (2048x1584 around 1024x576). So a clip can be drawn at any size and
// still cover the whole band, even a phone's tall one, with no visible edge.

/** How the band moves from one clip to the next. */
export type Handoff =
  | 'push'      // the clip speeds out left while the next comes in from the right
  | 'slide-out' // the clip speeds out left, uncovering the next one already playing
  | 'cut'       // the next clip simply replaces it

export type ReelClip = {
  readonly src: string
  /** The animation's size, from the space under the text (--stage) so its drawing fills about
   *  95% of that height (16:9, never past 720px tall so it stays sharp), and how far up to lift
   *  it so the drawing, not its frame, is centred. Its canvas spills past it on every side. */
  readonly box: string
  /** How this clip hands over to the next one when it ends. */
  readonly handoff: Handoff
}

export const HANDOFF_MS = 650

export const REEL: readonly ReelClip[] = [
  {
    // The van is the widest drawing (about 5/8 of its frame), so it also keeps inside the screen.
    src: '/hero/hero-van',
    box: 'h-[min(calc(var(--stage)*1.42),720px,calc((100vw-48px)*0.87))] w-[min(calc(var(--stage)*2.52),1280px,calc((100vw-48px)*1.55))] -translate-y-[51.5%]',
    handoff: 'push',
  },
  {
    src: '/hero/hero-laptop',
    box: 'h-[min(calc(var(--stage)*1.79),720px)] w-[min(calc(var(--stage)*3.18),1280px)] -translate-y-[53.5%]',
    handoff: 'slide-out',
  },
  {
    src: '/hero/hero-shopper',
    box: 'h-[min(calc(var(--stage)*1.58),720px)] w-[min(calc(var(--stage)*2.81),1280px)] -translate-y-[57%]',
    handoff: 'cut',
  },
]

export function nextClip(index: number, count: number = REEL.length): number {
  return (index + 1) % count
}
