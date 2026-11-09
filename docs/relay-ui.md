# Relay UI

The relay's administration UI is framework-free and ships inside the Rust binary.
It does not use the separate Vite demo application or require an asset server.

## Shared UI layers

- `crates/highlite-relay/src/ui-theme.css` owns the highlighter yellow, orange, and
  pink palette, typography,
  spacing, radii, and shadow tokens. Change visual foundations here rather than
  introducing recipe-specific colors.
- `crates/highlite-relay/src/ui-components.css` owns shared controls, panels,
  notices, field grids, cards, settings rows, and wizard layouts. Components compose
  these classes and inherit the theme.
- `crates/highlite-relay/src/ui-components.js` owns reusable wizard navigation,
  validation behavior, and view navigation. These components do not send relay API
  requests or manage recipe settings.
- `crates/highlite-relay/src/ui.html` owns page markup and application behavior,
  including recipe-specific fields, configuration requests, and session review.

`ui_index` in `crates/highlite-relay/src/lib.rs` embeds these assets into the HTML
template. The three `highlite:` placeholders are internal insertion points, not
external asset URLs. Rebuild the relay after changing any UI asset.

## Application views

The main navigation separates three screens. Only one is visible at a time:

- **Sessions** (`#sessions`) contains the capture list, session details, recipe-run
  review and publication, and pipeline runs.
- **Recipes** (`#recipes`) contains recipe setup and configuration—not captured
  sessions or their run output.
- **Providers** (`#providers`) contains reusable AI connections and credentials.

View navigation and wizard navigation are separate concerns. Changing views must
not advance the wizard, reset unsaved recipe fields, or reload the recipe form over
edits. The recipe's **Open Providers** action makes a round trip to the Providers
screen, with a return action that resumes the instructions step. Navigation uses
safe view fragments, supports browser Back/Forward, and never includes credentials.
The startup read-token fragment is consumed and removed before view navigation.

Configuration requests must not change which screen is visible when they complete.
The active view alone controls screen visibility; authentication hides every screen
until access is established. Session refresh and polling must not bring the session
browser into a settings screen.

## Recipe setup

Both first-time setup and editing use a four-step walkthrough: connection, destination,
instructions, and activation. Only one step is visible at a time. Navigation
must preserve entered values without saving partial configuration. The final save
validates the whole form, including fields in other steps or advanced disclosures.

New recipes should reuse the shell and UI primitives, but provide their own fields,
validation, and outcome summaries. Step content should follow the workflow: choosing
an outcome, configuring connections, providing instructions where needed, and
reviewing activation and data sharing. Do not force non-AI workflows to have prompts
or add a general-purpose dynamic form engine for a single recipe.

Keep these safety boundaries:

- Credential inputs are write-only. Never include them in summaries, storage,
  diagnostics, or URLs.
- Saving configuration does not verify credentials, generate content, or publish.
- The explicit connection test verifies Jira account access and loads create-enabled
  projects without saving credentials. Project selection loads named issue types.
  Account edits invalidate the test and choices; late responses cannot overwrite newer
  selections or signed-out state. Never follow Jira-provided pagination URLs.
- Review-before-publication remains the default. Automatic publication and image
  sharing need explicit, nearby explanations.
- Describe enabled, automatic-drafting, and publication settings together; a disabled
  recipe or manual trigger must not be described as running automatically.
- Keep keyboard navigation, field labels, visible focus, responsive layouts, and
  validation of hidden fields working in both wizard and edit modes.

## Validation

Run `pnpm check` and `pnpm test:recipes`. The recipe browser smoke test uses local
fake AI and Jira services, not live credentials or paid model calls. Use
`HIGHLITE_UI_SCREENSHOT_DIR=/tmp/opencode/highlite-ui pnpm test:recipes` to capture
the setup and editing screens for visual review.
