# Agent bundle

`highlite-compiler bundle` turns a capture into a folder an agent can read without the
original app, video, or browser session.

```sh
highlite-compiler bundle ./capture --out ./capture-bundle \
  --model ~/.local/share/whisper/ggml-base.en.bin
```

## Read it in this order

1. **`summary.md`** — the paste-ready handoff. Each line is a selected keyframe: `#index`,
   time, the action or cue, and the narration tied to that moment. Docs refs follow.
2. **`contact-sheet.png`** — every selected keyframe in one image. Use it to decide which
   frame to open.
3. **`frames/frame-XX.png`** — the cropped, annotated frame named by the summary's `#index`.
   Annotations are burned into the pixels; crops focus on the target or annotation.
4. **`scrawl.json`** — structured keyframes, transcript with word timings, marks, strokes,
   events, and target/window metadata.
5. **`bundle.json` / `analysis.json`** — the full `CompiledBundle` and `CaptureAnalysis` for
   tooling: scores, crop rects, event alignment, docs refs, warnings.

## Suggested agent prompt

> Read `summary.md`, then open `contact-sheet.png`. For each `#n` that matters, open
> `frames/frame-NN.png` and use the narration on that line as the intent. Consult
> `scrawl.json` for exact targets, annotations, and word timings. Treat
> `## Capture limitations` as missing evidence, not as something to guess around.

## Guarantees

- Frame indices in `summary.md` match `frames/frame-NN.png` and `scrawl.json`.
- Crops are applied to the stored pixels; `crop` in `bundle.json` records the normalized rect.
- Every annotation on screen when a keyframe was captured is referenced by that keyframe and
  burned into its image at the stroke width the user drew. Annotations hold for two seconds,
  then fade out; mid-fade keyframes still burn the stroke at full opacity for readability.
- Crops include the DOM target and every annotation burned into the frame, so annotations are
  never cut off at the edge.
- A spoken cue that had no captured frame is reported as a warning instead of fabricating one.
- Transcript times are on the session clock; ASR audio offsets are applied during compilation.
