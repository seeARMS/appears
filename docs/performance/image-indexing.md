# Image indexing investigation

2026-10-16. Branch: `codex/image-indexing-investigation`, based on main
`079ee6a` (PR #43). The indexer now prepares one following photo while the
current photo runs through the model. The change is local to this branch and has
not been installed in the running app.

## Integrated indexer

`Indexer.indexPending()` now overlaps decode, accurate OCR and CPU pixel
preparation for at most one following file or downloaded Messages photo. Text
and image forwards still use the shared scheduler, with queries taking the next
slot. PDFs retain their existing per-item path. The model ID, 1024-pixel decode
limit, OCR thresholds and 280-token image budget are unchanged; existing vectors
remain valid.

Prepared photos carry their settings revision, Messages context revision and
stored content signature. Neighbouring message edits also invalidate prepared
conversation text when the attachment itself is unchanged.
Checks before embedding and saving reject obsolete work; SQLite also guards the
unit replacement by signature. File size, precise modification date and file ID
catch edits/deletions before a watcher reconciles them. Changed, readable photos
stay pending and are prepared again, including same-size edits within one
second. Missing photos fail until a scan removes or updates them. Cancellation
and settings changes cancel preparation; the run drains it before returning so
another run cannot accumulate background decoders. The existing 120-second
budget remains cooperative: native work must return before it can be drained.

The integrated benchmark uses all 18 JPEG/PNG demo files, the real model, and the
production scheduler, extractor, index store and vector insertion. Serial runs
call `Indexer.index(_:)` for each photo; prefetch runs call
`Indexer.indexPending()`. It keeps the towers loaded between modes to compare
steady indexing, whereas production unloads vision after a run. It excludes a
complete warmup pass through all images, then runs serial / prefetch / prefetch /
serial at the engine's medium priority (21). Unlike the prototype below, this
fixture uses file OCR without an added Messages conversation.

| Run | Elapsed seconds | Sampled peak process footprint, bytes |
| --- | ---: | ---: |
| Serial 1 | 3.605 | 3,338,537,120 |
| Prefetch 1 | 2.765 | 3,350,022,400 |
| Prefetch 2 | 3.293 | 3,338,373,304 |
| Serial 2 | 4.393 | 3,343,960,248 |

Mean elapsed: **3.999 s serial versus 3.029 s prefetch**, **24.3% less time** or
**1.32x throughput**. The selected Xcode test passed (1 passed, none failed or
skipped). Saved unit metadata/text matched exactly; saved float16 text/image
vectors all matched with cosine similarity greater than 0.99999.

Process footprint was sampled every 5 ms using `TASK_VM_INFO.phys_footprint`.
Both modes peaked around 3.11 GiB in the same process with warm model caches.
These samples do not isolate the additional prepared photo's allocation or prove
long-run memory behavior. The deterministic core tests separately enforce the
one-photo lookahead and check query priority, cancellation/draining, source
exclusions, stale signatures, neighbouring Messages edits, physical edits/deletions
and timeout failures.

An initial integration run had a 34.6-second first serial pass; it is excluded
from this comparison. The reported rerun warms the full fixture before timing,
so it does not compare the first full pass with subsequent warm passes.

## Validation

- AppearsKit: 141 tests passed (126 Core, 10 Context, 5 MCP).
- Script tests: all 8 passed.
- `mac/scripts/test-model.sh`: 5 model/MCP tests passed, none skipped. Eval:
  recall@3 0.99, MRR 1.00, ambient hits 23/23, false surfaces 0/22,
  open file shown 0, matched lines 3/3.
- Clean Release app build, followed by a rebuild after the Messages context
  invalidation change: strict/deep signature verification, the no-network and
  sandbox-boundary check, and verification of all 30 bundled notices passed.

## Original stage-timing prototype

What ran:

- Real local EmbeddingGemma 2 model, 768 dimensions, existing 280-token image budget.
- Release build on the M5 Max Mac, with measured work at task priority 21, matching
  the engine's medium priority. No concurrent MLX model forwards.
- All 18 JPEG/PNG images in `demo/files`, plus the same made-up conversation on
  each photo to exercise the text work done for Messages attachments.
- The current image decode, accurate OCR, text thresholds, image preprocessing,
  text/image encoders, SQLite unit replacement and in-memory vector insertion.
- One warmup, then serial / prefetch / prefetch / serial order. Each prefetch run
  prepares at most one following photo while the current model work runs.
- The final selected Xcode test actually executed: 1 passed, 0 failed, 0 skipped.
  Every text and image vector in each run matched its serial counterpart with
  cosine similarity greater than 0.99999.

No personal photos, Messages database or real index were opened by the benchmark.
The synthetic index is temporary and removed after each run.

### Prototype results

Times below are seconds for all 18 images. Stage times in a prefetch run overlap,
so their sum exceeds elapsed time.

| Run | Elapsed | Decode | OCR | Image preparation | Text encode | Image encode | Save |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Serial 1 | 3.869 | 0.159 | 1.946 | 0.324 | 0.228 | 1.203 | 0.008 |
| Prefetch 1 | 2.762 | 0.162 | 2.188 | 0.310 | 0.220 | 1.091 | 0.008 |
| Prefetch 2 | 2.548 | 0.153 | 1.986 | 0.310 | 0.218 | 1.001 | 0.007 |
| Serial 2 | 3.691 | 0.147 | 2.010 | 0.313 | 0.220 | 0.992 | 0.007 |

Mean elapsed time: **3.780 s serial versus 2.655 s prefetch**, a **29.8% reduction**
or **1.42x throughput** on this fixture. About 52% of serial time is OCR, 29% is
image encoding, 8% is image preparation, 6% is text encoding, and under 1% is
saving. Rebuilding the image token IDs costs about 0.52 ms per photo here, so
caching those IDs alone would have little effect.

The MLX peak counter was 1,841,764,215 bytes across the whole test. This is not a
measurement of total process memory or a comparison of peak memory by mode.
The 0.566 s warmup is excluded and starts after text-model loading. System and
compiler caches had already been warmed by earlier attempts.

An earlier run at the test runner's priority 25 also favored prefetch, but its
absolute times were higher and more variable. The table uses only the subsequent
run at the engine's priority. Zero-test and interrupted broad-filter attempts
are excluded from the results.

## Further experiments

Batching images would require a separate change: the vision implementation
currently fixes the batch dimension to one. Batching text across neighboring
photos is another experiment, subject to the scheduler's existing eight-document
limit and padding costs. Keep the 280-token image budget while measuring these.

## Reproduce

The benchmark source is
`mac/Packages/AppearsModel/Tests/GemmaEmbedderTests/ImageIndexingBenchmarkTests.swift`.
From `mac/Packages/AppearsModel`, use an existing local model and a fresh result
bundle path:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export APPEARS_MODEL=/absolute/path/to/appears-model
export TEST_RUNNER_APPEARS_MODEL="$APPEARS_MODEL"
xcodebuild test -scheme AppearsModel-Package \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ../../build/ImageInvestigationDerivedData \
  -configuration Release ENABLE_TESTABILITY=YES \
  '-only-testing:GemmaEmbedderTests/GemmaEmbedderTests/imageIndexerBenchmark()' \
  -resultBundlePath ../../build/ImageBenchmark.xcresult
xcrun xcresulttool get test-results summary --path ../../build/ImageBenchmark.xcresult
xcrun xcresulttool export diagnostics --path ../../build/ImageBenchmark.xcresult \
  --output-path ../../build/ImageBenchmarkDiagnostics
rg 'IMAGE_INDEXER' ../../build/ImageBenchmarkDiagnostics -g StandardOutputAndStandardError.txt
```

For the original stage profiling, select `imageIndexingBenchmark()` instead and
filter diagnostics for `IMAGE_BENCH`. Use a fresh result bundle for each run.

Keep the parentheses in the Swift Testing selector and verify that exactly one
test passed. Xcode's console-log export did not contain standard output; the
diagnostics export did.

These are preliminary measurements on a small synthetic fixture on a shared
Mac. They exclude Messages database reads, filesystem scanning and foreground
search traffic. They do not establish a speedup for the full personal library or
for the running app. The implementation has not been installed in the running app.
