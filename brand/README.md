# Appears brand

Direction E, "shadcn", chosen 2026-10-15 from the five explored on the design canvas. Appears looks like a modern tool built with shadcn/ui: zinc neutrals, hairline borders, small radii, a black primary, muted secondary text, and a ⌘K-style results list. Don't use Geist or Liquid Glass capsules, and don't bring back the earlier warm-paper/serif look.

- **Mark:** **Orbit**, chosen by Colin on 2026-10-15. An open ring leaves a gap at the upper right for a detached discovery dot. `mark.svg` puts it in white and blue on a zinc tile; `app-icon.svg` adds the Mac icon's transparent margin. Keep the gap, dot separation and round stroke caps from the approved drawing.
- **Wordmark:** lowercase "appears", Inter 700, letter-spacing -0.04em, next to the mark. The product name in sentences is "Appears", capitalized.
- **Menu bar glyph** (drawn in code, `mac/App/Sources/Glyph.swift`), as template images:
  - idle: the open orbit;
  - indexing: a shorter arc with a wider gap, still and quiet;
  - found: the orbit and detached filled dot rotate clockwise together continuously until the waiting result is opened or cleared; each full turn takes four seconds, with no pause between turns;
  - paused: the orbit with two pause bars inside;
  - needs setup: the orbit with an exclamation mark inside.
  All five are monochrome, including the found dot. Blue belongs to the brand mark, not the menu bar. Only found animates; Reduce Motion keeps it still, and display sleep suspends the animation.
- **Geometry:** the symbol uses a 24-point square: arc center `(11.5, 12.8)`, radius `7.5`, stroke `2.1`, running clockwise on screen from 10° to 270° (indexing ends at 4.06 radians). The discovery dot is centered at `(17.5, 6.4)`, radius `2.65`. On a tile, inset the symbol by 17% and use a corner radius of 23.5% of the tile width.
- **Sources:** `mac/App/Sources/Orbit.swift` shares the app drawing between its menu bar, mark and onboarding. `web/src/lib/orbit.ts` shares the site, favicon, share card and generated SVG/PNG assets. From `web/`, run `npm run brand` to regenerate the SVGs and all Mac icon sizes, and `npm run og` to refresh the share card. Neither command needs network access.
- **Colour** (shadcn zinc tokens):

  | Token | Light | Dark |
  | --- | --- | --- |
  | background | `#FFFFFF` | `#09090B` |
  | card / popover | `#FFFFFF` | `#18181B` |
  | muted (hover, selected row) | `#F4F4F5` | `#27272A` |
  | border | `#E4E4E7` | `#27272A` |
  | muted-foreground | `#71717A` | `#A1A1AA` |
  | foreground | `#09090B` | `#FAFAFA` |
  | primary (buttons) | `#18181B` | `#FAFAFA` |
  | accent | `#2563EB` | `#3B82F6` |

  The accent is the only colour. Use it sparingly: the brand mark's discovery dot, links, focus rings.
- **Type:** Inter on the web; the system font (SF) in the Mac app. Weights 400, 500 and 600, with 700 for the wordmark only.
- **Shape:**
  - radius 8 px for cards and popovers, 6 px for buttons and rows, full for badges;
  - borders 1 px;
  - shadows only on floating things (the panel).
- **Voice:** calm, plain, short. Never "AI-powered", never exclamation marks.
