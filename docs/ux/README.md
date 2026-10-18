# Source health, search updates and passage previews

These light and dark screenshots use only made-up demo files, notes and messages. They are rendered by `appears-snapshots`; no personal index, conversation, screen capture or calendar is used.

To regenerate from the repository root, build the `appears-snapshots` Release scheme with Xcode, then run the resulting executable. Images are written to `mac/build/snapshots`. The same run verifies search request ordering, selection, clearing, failures, launch-event routing and the related list’s scrolling behavior.

Run the same executable with `--glyph-preview` to verify discovery animation on a native status button and render `mac/build/snapshots/menu-bar-rotation.gif`. It shows a waiting match rotating continuously in light and dark, with the production icon at menu bar size and 4× magnification. The eight-second loop contains two full turns with no pause. The surrounding menu bar is synthetic; the drawing and timing come directly from `GlyphImage`.

The checked-in [animation](../media/menu-bar-rotation.gif) and [still frame](menu-bar-rotation.png) show both appearances for review.

`source-health` shows a ready index; `source-health-indexing` shows a partial index and missing permissions. `source-health-queued` shows existing searchable Messages without a saved scan date, a queue awaiting indexing, and the Scan now button at the top of Sources. `search-updating` keeps the previous results visible while a new query runs. The note and message previews show the indexed passage or conversation, with actions to copy it or open the original.

`source-health-skipped` shows a usable index with a skipped, inaccessible folder. `source-health-checking` shows a source scan while indexing is already active, with Scan now disabled until the check finishes. Both use a made-up folder path.
