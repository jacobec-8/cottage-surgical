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
  /** Where the animation sits in the band; its canvas spills past this box on every side. */
  readonly box: string
  /** How this clip hands over to the next one when it ends. */
  readonly handoff: Handoff
}

export const HANDOFF_MS = 650

export const REEL: readonly ReelClip[] = [
  {
    src: '/hero/hero-van',
    box: 'w-[640px] h-[360px] top-[335px] sm:w-[764px] sm:h-[430px] sm:top-[205px] lg:w-[1120px] lg:h-[630px] lg:top-[140px]',
    handoff: 'push',
  },
  {
    src: '/hero/hero-laptop',
    box: 'w-[675px] h-[380px] top-[337px] sm:w-[805px] sm:h-[453px] sm:top-[198px] lg:w-[1000px] lg:h-[563px] lg:top-[183px]',
    handoff: 'slide-out',
  },
  {
    src: '/hero/hero-shopper',
    box: 'w-[652px] h-[367px] top-[352px] sm:w-[770px] sm:h-[433px] sm:top-[222px] lg:w-[1000px] lg:h-[563px] lg:top-[204px]',
    handoff: 'cut',
  },
]

export function nextClip(index: number, count: number = REEL.length): number {
  return (index + 1) % count
}
