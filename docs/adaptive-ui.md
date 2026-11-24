# Adaptive UI

How the interface adapts to the device it is shown on, and how each claim made
here is verified rather than asserted. The implementation is in `web`, and the
design system is reachable in the running application at `/design-system`.

## Device Coverage

| Class | Reference viewport | Layout |
|---|---|---|
| Phone, portrait | 390 x 844 | Single column. Tables reflow into labelled cards. Navigation collapses into a persistent bar |
| Phone, landscape | 844 x 390 | Single column with reduced vertical rhythm, since height is the scarce dimension |
| Tablet | 820 x 1180 | Two columns where content pairs naturally, full table layout |
| Desktop | 1440 x 900 | Full layout, inline navigation, side-by-side evidence |
| Ultrawide | 2560 x 1080 | Content bounded by a maximum measure and centred, so lines do not become unreadable |

Screenshots of every screen at each of these viewports are in
[`screenshots`](screenshots), captured from the running application rather than
drawn.

## Breakpoints

Three widths, expressed in `rem` so that they respond to the reader's font size
rather than to a pixel count:

| Breakpoint | Width | Effect |
|---|---|---|
| `30rem` | 480px | Below it, the appearance panel spans the width rather than hanging from the right edge, where it would be cut off |
| `48rem` | 768px | The principal change: tables become tables, navigation moves inline, multi-column layouts begin |
| `64rem` | 1024px | Evidence appears beside the entry it explains rather than beneath it |

Four further queries adapt to the device rather than to its width:

- `pointer: coarse` raises every interactive element to the minimum touch
  target, so a touch device gets larger controls regardless of its width.
- `orientation: landscape` on a short viewport compresses vertical spacing.
- `prefers-color-scheme` selects the initial theme.
- `prefers-reduced-motion: reduce` removes transitions for readers who have
  asked their system for that.

This is the automatic detection: pixel density through `rem` units and
`devicePixelRatio`-independent SVG, orientation and pointer type through the
queries above, and colour scheme from the system. Nothing depends on a user
agent string.

## Design System

`src/styles/tokens.css` is the single source of every colour, type step,
spacing step, radius, shadow and the touch target minimum. Components reference
tokens and never literal values, which is what keeps the palette and the
typography identical across devices and themes.

| Token group | Purpose |
|---|---|
| Surfaces, text, accent | The base palette, defined three times: light, system dark, and explicit dark |
| Risk colours | High, medium and low, each also distinguished by a label and a shape so colour is never the only carrier |
| Borders | A normal line, and a strong line for the edge of a control, which WCAG 1.4.11 holds to 3:1 |
| Chart marks | Separate from text, since a mark is held to 3:1 rather than 4.5:1 |
| Type scale | Five steps in `rem`, with two line heights and three weights |
| Spacing | A single scale, used for both layout and component padding |
| `--touch-target` | `2.75rem`, the 44px minimum of WCAG 2.5.5 |
| `--measure`, `--layout-max` | The readable line length and the maximum content width |

## Component Library

`/design-system` renders every reusable component in every state it can occupy,
which makes it both the reference for the design and a visual regression
surface. It covers colour with its contrast figures, the type scale, the
spacing scale, buttons in every state, risk bands, badges, figures, the four
asynchronous states, the charts and the breakpoints themselves.

The components are grouped by the area that owns them:

| Group | Components |
|---|---|
| `ui` | Button, Card, Badge, States (loading, skeleton, empty, failure), icons |
| `layout` | AppShell, Appearance, Notices |
| `report` | TreeTable, DataAgeBanner |
| `charts` | FactorBars, DownloadChart |
| Input | FileDrop |

Interactive states are defined for rest, hover, active, focus and disabled.
Focus uses `:focus-visible`, so a keyboard reader sees a ring and a pointer
user does not. Icons are inline SVG, which scales without distortion at any
pixel density and inherits the text colour, so it follows the theme without a
second asset.

## Reader Controls

Two preferences are the reader's to set, in the appearance control in the
shell:

- **Theme**, as system, light or dark. The choice is written to the document
  root as `data-theme` and persisted, so a reload keeps it.
- **Text scale**, at three steps applied to the root font size. Because every
  dimension in the stylesheet is relative, enlarging text enlarges spacing,
  controls and touch targets with it instead of overlapping them.

## Structural Behaviour

The layout is rebuilt rather than merely narrowed when the width changes. The
report tree is the clearest case: on a wide viewport it is a table with a
header row, and below `48rem` each row becomes a card in which every cell is
preceded by its own label.

That reflow is done with real elements rather than CSS generated content, and
the ARIA roles for table, row group, row, column header and cell are stated
explicitly. Changing `display` on a table strips its implicit semantics, so
without those roles the phone layout would have been a flat list of text to a
screen reader. CSS generated content is not dependably exposed to assistive
technology either, which is why each label is an element.

The main navigation is present at every width. Above the breakpoint it is
inline in the header, below it a persistent bar, and exactly one of the two is
visible at any time.

## Accessibility

Level AA of WCAG 2.1 is the target, and three of its requirements are checked
automatically rather than reviewed:

- **1.4.3 Contrast, minimum.** `src/styles/contrast.test.ts` computes the
  ratio of every foreground and background pair in the token file, in both
  themes, and asserts 4.5:1 for text.
- **1.4.11 Non-text contrast.** The same suite asserts 3:1 for control edges
  and chart marks.
- **2.5.5 Target size.** The end to end suite measures a control on a phone
  viewport and asserts at least 44 pixels.

Beyond those: every control is reachable and operable by keyboard, every image
and icon carries a text alternative or is marked decorative, headings descend
without skipping, notices are announced through a live region, and colour is
never the sole carrier of meaning, since each risk band also has a label and a
shape.

## Verification

The claims above are tested in `web/e2e/adaptive.spec.ts`, which runs in
Playwright against the demonstration build:

| Test | Assertion |
|---|---|
| Every viewport in the table above | The navigation is reachable, and exactly one of the two navigations is visible |
| Every viewport | `scrollWidth` does not exceed `clientWidth`, so nothing overflows horizontally |
| Phone | A filter control measures at least 44 pixels |
| Phone | The layout survives the root font size doubling, which is how a browser applies zoom, with no horizontal overflow and the heading still visible |
| Phone | The theme can be chosen and survives a reload |

`src/components/ui/States.test.tsx` asserts the remaining structural claim:
that a state occupying the whole screen carries the `h1`, so no screen begins
at `h3` and no screen is left without a first heading.

Three defects were found by running these rather than by inspection: the ARIA
roles lost to the table reflow, visually hidden radio inputs that could not be
clicked because they had `pointer-events: none`, and the failure and empty
screens beginning at `h3` with no `h1` above them. All three are fixed.

The chart palette was validated for colour vision deficiency rather than chosen
by eye. The first dark-theme pair failed deuteranopia simulation, and the
replacement separates its two series by hue against blue instead of by red
against green.

## Known Limitations

Foldable devices are handled only as the two widths they present, since the
CSS viewport segment queries are not yet broadly supported. Smartwatch
viewports are out of scope: the narrowest layout assumes a readable table of
dependency names, which does not fit a display of that size. Both would need a
different information design rather than another breakpoint.
