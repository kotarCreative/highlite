# Highlite brand and UI tokens

The relay dashboard, the native macOS app, and the browser capture recorder share
one highlighter identity. The palette is not a generic set of pastels: warm paper
surfaces carry ink text, highlighter yellow paints primary actions, and pink and
orange are supporting marker accents. Status colors stay semantic.

## Source of truth

- `crates/highlite-relay/src/ui-theme.css` defines the canonical light palette,
  spacing, radii, shadows, and type tokens. `ui-components.css` composes them.
- `packages/sdk/src/theme.ts` mirrors the recorder palette and adds dark
  appearance overrides plus annotation ink.
- `apps/macos/Sources/HighliteMenuBar/Views/DashboardStyle.swift` mirrors the same
  palette as dynamic AppKit colors with light and dark values.

Change all three when a brand token changes, and update the tests in
`packages/sdk/tests/theme.test.ts` and
`apps/macos/Tests/HighliteMenuBarTests/DashboardThemeTests.swift`.

## Palette

| Token              | Light                 | Role                                                  |
| ------------------ | --------------------- | ----------------------------------------------------- |
| canvas             | `#fffdf5`             | Warm page and sidebar canvas                          |
| surface            | `#ffffff`             | Cards, panels, dialogs, code controls                 |
| surface-muted      | `#fffbf0`             | Inset code blocks and quiet fills                     |
| ink                | `#30232d`             | Primary text and dark control surfaces                |
| muted              | `#75636c`             | Secondary text and metadata                           |
| line / line-strong | `#eadfda` / `#c9b7bd` | Card borders and control outlines                     |
| primary            | `#a92261`             | Links, focus rings, selected navigation, card icons   |
| primary-soft       | `#fff0f6`             | Informational banners and selected-row fill           |
| highlight-yellow   | `#efff3d`             | Primary actions, active tools, title marker           |
| highlight-orange   | `#ffad60`             | Supporting marker accent, such as Mark                |
| highlight-pink     | `#ff81bd`             | Supporting marker accent, active navigation underline |
| success            | `#087443`             | Ready, published, submitted                           |
| warning            | `#9a5700`             | Queued, analyzing, retry needed                       |
| danger             | `#b4232d`             | Failure, destructive actions                          |

The vivid accents keep dark ink (`#30232d`) rather than white text. Destructive
buttons keep a red surface with light text because their meaning must not be
diluted by the highlighter palette.

## Application hierarchy

- **Surfaces:** warm canvas behind the work, white cards for content, muted warm
  fill for code and inset areas. Borders and shadows stay subtle.
- **Typography:** ink for titles and body, muted for metadata. Page titles get a
  short yellow marker stroke, mirroring the relay brand wordmark. The macOS
  marker is deliberately translucent (`DashboardStyle.titleMarkerOpacity`) so
  light ink stays readable in Dark Aqua; it is decoration, not a text surface.
- **Iconography:** the native app and menu bar use a highlighter mark rather
  than a generic sparkle. `apps/macos/Resources/AppIcon.svg` is the icon source,
  the committed `AppIcon.icns` is bundled as `CFBundleIconFile`, and
  `pnpm generate:macos-icon` rebuilds the ICNS from the vector.
- **Actions:** yellow primary buttons use dark ink, a thin dark outline, and a
  small offset shadow. Secondary controls stay on white with line-colored
  borders. Tinted controls use the magenta primary, never the yellow action
  color, so the bright paint remains reserved for the main action.
- **Recorder dock:** the floating recording dock uses the warm ink surface in
  both appearances so it remains legible over any host page. Active annotation
  tools paint yellow with dark icons, Mark uses orange, and Stop keeps its
  semantic red.
- **Status:** success, warning, and danger remain separate from decorative
  accents and always appear with readable contrast.

## Appearance and scope

- The macOS palette resolves light values under Aqua and the ink/pink values
  under Dark Aqua. Window minimums, keyboard focus, and native controls are
  unchanged.
- Recorder styles live in the toolbar's Shadow DOM, so host-page CSS cannot leak
  in or out. The recorder also provides a dark appearance for its panels and
  overlays while the dock intentionally keeps its ink surface.
- The demo application (`apps/demo`) is a host site used to exercise the SDK.
  Its own northstar dashboard styling is intentionally not rebranded; only the
  Highlite recorder chrome is in scope.

## Validation

- `pnpm test` covers the shared recorder palette, contrast, dark tokens, and
  annotation colors.
- `node scripts/browser-smoke.mjs` checks the rendered recorder dock and active
  tool colors after building the SDK.
- `swift test --package-path apps/macos` covers the native palette, dark
  appearance, title-marker contrast, and other contrast assertions on macOS.
  Linux cannot run the SwiftUI build or visual checks.
- `pnpm verify:macos` statically checks the icon source, generated ICNS
  structure, plist declaration, and packaging script on Linux; the macOS run
  verifies the bundled icon alongside the signed app.
