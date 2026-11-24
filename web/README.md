# Browser Application

The client for the dephealth API. React, TypeScript in strict mode, Vite. It
submits a dependency manifest, renders the resulting tree ranked by risk, and
shows the evidence behind each score.

Architecture, user flows and the justification of this stack are in
[`docs/frontend.md`](../docs/frontend.md). The responsive design, the design
system and the accessibility verification are in
[`docs/adaptive-ui.md`](../docs/adaptive-ui.md).

## Configuration

Copy [`.env.example`](.env.example) to `.env.local`. Vite exposes only
variables prefixed with `VITE_`, and every one of them reaches the browser, so
no secret belongs in that file. `VITE_DEMO=true` serves the application from
the responses committed in `src/api/fixtures`, which is how the deployed demo
and the end to end tests run with no service behind them.

## Commands

`npm run` lists the scripts. Three are not self-evident: `build:demo` produces
a bundle served from the committed fixtures, `e2e` runs Playwright across a
desktop and a mobile viewport, and `screenshots` captures every screen at every
supported viewport.

## Layout

| Path             | Contents                                                        |
| ---------------- | --------------------------------------------------------------- |
| `src/api`        | Request layer, generated types, problem handling, demo fixtures |
| `src/pages`      | One component per route, loaded lazily                          |
| `src/components` | Presentation, grouped by the screen area that owns it           |
| `src/store`      | Client state, zustand, persisted where it belongs to the viewer |
| `src/hooks`      | Request lifecycle and appearance preferences                    |
| `src/lib`        | Parsing, risk ranking, contrast and logging                     |
| `src/styles`     | Design tokens and global rules                                  |
| `e2e`            | Playwright specifications                                       |
