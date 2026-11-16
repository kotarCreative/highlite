# Bug-report pipeline data contract

This document defines the seam between a compiled Highlite capture and a future bug-report
generator. The current implementation produces the evidence and a report-ready action list;
it does **not** publish issues, post to an external tracker, or replay a session.

## What the SDK captures

With `capture.interactions` enabled, the browser SDK records user-facing actions in session
order:

| Kind         | Meaning                                                                            |
| ------------ | ---------------------------------------------------------------------------------- |
| `click`      | A click on a non-form target.                                                      |
| `scroll`     | A debounced window scroll position.                                                |
| `navigate`   | An SPA route change, with sanitized before/after URLs.                             |
| `input`      | A coalesced text-edit burst in a supported text field. No per-key events.          |
| `change`     | A select (including every option of a multiple select), checkbox, or radio change. |
| `submit`     | A form submit with the form and submitter labels.                                  |
| `mark`       | An explicit user mark.                                                             |
| `annotation` | A drawn annotation.                                                                |
| `target`     | Internal target metadata for a nearby action; omitted from reports.                |
| `context`    | Caller-supplied context or the bounded environment record.                         |

Form targets use associated labels, `aria-labelledby`, `aria-label`, and other accessible
hints where available. A field type (`fieldKind`, `fieldType`) is always recorded. Values are
omitted by default. `capture.formValues: true` opt-in allows values for supported ordinary
fields; password, hidden, file, private, disabled, and secret-like fields are always excluded.
A sensitive-looking label ("API token") keeps the action but drops the value.

Clicks on captured non-submit fields are suppressed so the report does not show both a click
and the semantic input/change it caused. A submit-button click is held until the current task
finishes: if the browser fires `submit`, only the submit action is kept; if native validation
or a click handler blocks submission, the click is recorded as the evidence of the failed
attempt. A multiple select records every selected option label in `optionLabels`; an empty
list means the selection was cleared.

At start the SDK records one `context` event with `scope: "environment"` containing a bounded
browser/platform/viewport string. Application versions should use the same channel:

```ts
capture.context('app.version', '1.4.2');
```

No network requests, console logs, cookies, local storage, clipboard, or full user agent are
captured by this feature.

## Compiler output

`highlite-compiler bundle` writes `summary.md` and `report.json`. The report is also embedded
at `bundle.json.report` and emitted by `highlite-compiler compile`.

`report.json` shape (`schemaVersion: "0.1.0"`):

```json
{
  "schemaVersion": "0.1.0",
  "sessionId": "session-1",
  "page": { "initialUrl": "https://app.example.com/search", "title": "Search" },
  "viewport": { "x": 0, "y": 0, "width": 1440, "height": 1000 },
  "environment": [
    { "scope": "environment", "value": "Chrome 141 · Linux · viewport 1440×1000" },
    { "scope": "app.version", "value": "1.4.2" }
  ],
  "actions": [
    {
      "eventId": "event-input",
      "seq": 4,
      "atMs": 2200,
      "kind": "input",
      "action": "Entered “retention” in field “Search metrics”",
      "target": {
        "id": "t-input",
        "tag": "input",
        "role": "textbox",
        "label": "Search metrics",
        "selector": "#metric-search"
      },
      "field": { "kind": "text", "inputType": "search" },
      "value": { "captured": true, "text": "retention", "filled": true },
      "evidence": {
        "keyframeIds": ["f-click"],
        "frameMatch": "temporal",
        "transcriptSegmentIds": ["fs1"],
        "transcriptMatch": "approximate",
        "said": "I search for retention and pick the last 30 days.",
        "confidence": 0.7
      }
    }
  ],
  "narration": [
    {
      "id": "fs1",
      "startMs": 2000,
      "endMs": 4000,
      "text": "I search for retention and pick the last 30 days."
    }
  ],
  "context": [{ "scope": "feature", "value": "billing" }],
  "notes": ["Observed actions only: expected and actual outcomes are not inferred."],
  "limitations": ["...capture warnings..."]
}
```

Key properties:

- `actions` is ordered by timeline sequence and is independent of keyframe selection. Actions
  without a selected frame still appear.
- `target` includes only human-usable target fields. Internal target metadata is omitted.
  Selectors remain available for a future generator, but should be treated as optional.
- `value.captured` is authoritative. A value is present only when the SDK explicitly included
  it; the compiler never infers or reconstructs values. Multiple-select changes use
  `value.optionLabels` so every selection is retained; an empty array means cleared.
- `evidence.frameMatch` is `exact` only when the SDK recorded the event id on the frame at
  capture time. `temporal` is the nearest-frame heuristic. `transcriptMatch: "approximate"`
  means segment overlap or clause alignment, never word-level truth. `confidence` is a
  heuristic score, not a correctness guarantee.
- `notes` states that outcomes are not inferred. `limitations` carries capture warnings.
- URL fields are sanitized: query strings and fragments are dropped.

## Future generator seam

A future bug-report generator may consume `report.json` plus the bundle's `manifest.json`,
`analysis.json`, and selected frames. A conservative pipeline is:

1. Validate `report.schemaVersion` and reject unknown future versions.
2. Render the ordered actions as repro steps, using target labels rather than selectors when
   possible.
3. Attach only evidence marked `exact` as directly linked screenshots; label `temporal` frame
   links as "nearby frame".
4. Include transcript excerpts only with an explicit approximate-alignment label.
5. Ask the reporter for expected and actual behaviour. Do not infer a pass/fail outcome from
   the transcript, actions, or missing error UI.
6. Keep field values only when `value.captured` is true, and allow the reporter to redact
   individual steps before publishing.
7. Treat issue creation as a separate, explicit action with its own authentication.

The compiler deliberately does not include expected/actual fields, severity, root cause, or a
generated repro narrative. Those require reporter input or a separate, clearly labelled model
step. No external issue posting is implemented in this repository slice.

Other limitations:

- Coalesced `input` events are timestamped when the burst is committed (idle timer, two-second
  cap, or stop), not at the first keystroke. Ordering is preserved; frame/transcript links near
  a typing burst are approximate.
- A submit-button click is held only until the current task ends. A form that submits
  asynchronously later than that can therefore show both a click and a submit.
- Cross-origin iframe contents and closed shadow roots remain outside DOM capture.
