# Agent bundle

`highlite-compiler bundle` turns a capture into a folder an agent can read without the
original app or browser session. If the capture explicitly names a video file, `bundle`
copies that file alongside the bundle.

```sh
highlite-compiler bundle ./capture --out ./capture-bundle \
  --model ~/.local/share/whisper/ggml-base.en.bin
```

## Read it in this order

1. **`summary.md`** — the paste-ready handoff. It starts with the ordered observed actions,
   then the selected keyframes (`#index`, time, action or cue, narration tied to that moment),
   narration, environment/context, notes, and capture limitations.
2. **`report.json`** — the same actions as structured data: event ids, field metadata,
   opt-in values, exact/temporal frame links, approximate transcript ids, context, notes, and
   limitations. Use this instead of parsing Markdown for a bug-report pipeline.
3. **`contact-sheet.png`** — every selected keyframe in one image. Use it to decide which
   frame to open.
4. **`frames/frame-XX.png`** — the cropped, annotated frame named by the summary's `#index`.
   Annotations are burned into the pixels; crops focus on the target or annotation.
5. **`scrawl.json`** — structured keyframes, transcript with word timings, marks, strokes,
   events, and target/window metadata.
6. **`bundle.json` / `analysis.json`** — the full `CompiledBundle` and `CaptureAnalysis` for
   tooling: scores, crop rects, event alignment, docs refs, warnings.
7. **Video file (optional)** — a copy of `manifest.artifacts.video` when the capture named
   one, also listed as `Video: <name>` in `summary.md`. The compiler does not record video,
   and the file is not attached externally by default.

## Suggested agent prompt

> Read `summary.md`, then open `contact-sheet.png`. For each `#n` that matters, open
> `frames/frame-NN.png` and use the narration on that line as the intent. Treat
> `frame #n (exact)` links as capture-time evidence and `(temporal)` links as nearby guesses.
> Consult `scrawl.json` for exact targets, annotations, and word timings. Treat
> `## Capture limitations` as missing evidence, not as something to guess around.

## Guarantees

- Frame indices in `summary.md` match `frames/frame-NN.png` and `scrawl.json`.
- `report.json` lists every user-facing action in capture order, including actions that did
  not become a keyframe. Internal target rows are omitted.
- Field values appear only when the capture opted in and marked `valueCaptured: true`.
- Exact frame links come from capture-time event ids; temporal and transcript links are
  labelled as heuristics. The report never infers expected/actual outcomes.
- Crops are applied to the stored pixels; `crop` in `bundle.json` records the normalized rect.
- Every annotation on screen when a keyframe was captured is referenced by that keyframe and
  burned into its image at the stroke width the user drew. Annotations hold for two seconds,
  then fade out; mid-fade keyframes still burn the stroke at full opacity for readability.
- Crops include the DOM target and every annotation burned into the frame, so annotations are
  never cut off at the edge.
- A spoken cue that had no captured frame is reported as a warning instead of fabricating one.
- Transcript times are on the session clock; ASR audio offsets are applied during compilation.
- Video is copied only when the capture explicitly sets `artifacts.video`; paths that escape
  the capture folder are rejected, and the manifest records the copied file name. The copy is
  the recorder's file — not a recording made by `bundle`, not a claim of Scrawl format
  compatibility (see [compiler behavior](../crates/highlite-compiler/README.md#optional-video)),
  and not a default attachment (see [Jira publication modes](./jira-recipe.md#publication-modes)).
