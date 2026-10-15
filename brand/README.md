# Appears brand

Direction E, "shadcn", chosen 2026-10-15 from the five explored on the design canvas. Appears looks like a modern tool built with shadcn/ui: zinc neutrals, hairline borders, small radii, a black primary, muted secondary text, and a ⌘K-style results list. Don't borrow from whosaid or heade.rs (Geist, Liquid Glass capsules), and don't bring back the earlier warm-paper/serif look.

- **Mark** (`mark.svg`): a zinc-950 rounded tile with a white ring (what you're looking at) and a blue dot rising at its top (something you already had).
- **Wordmark:** lowercase "appears", Inter 700, letter-spacing -0.04em, next to the mark. The product name in sentences is "Appears", capitalized.
- **Menu bar glyph** (drawn in code, `mac/App/Sources/Glyph.swift`), as template images:
  - idle: a ring;
  - indexing: an open ring;
  - found: a ring with a filled dot at its top.
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

  The accent is the only colour. Use it sparingly: the found dot, links, focus rings.
- **Type:** Inter on the web; the system font (SF) in the Mac app. Weights 400, 500 and 600, with 700 for the wordmark only.
- **Shape:**
  - radius 8 px for cards and popovers, 6 px for buttons and rows, full for badges;
  - borders 1 px;
  - shadows only on floating things (the panel).
- **Voice:** calm, plain, short. Never "AI-powered", never exclamation marks.
