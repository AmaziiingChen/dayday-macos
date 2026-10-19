# O4-20260809-01 — Markdown editor interaction study

- **Repositories:**
  - https://github.com/MarkEdit-app/MarkEdit (MIT)
  - https://github.com/peterjthomson/marktext (MIT)
- **Research date:** 2026-08-09
- **Evidence:** repository README and license pages (O1); fixed-source inspection (O3) for the
  approved MarkEdit integration below.

## Question investigated

How should a lightweight, native macOS journal behave when Markdown is edited as an in-place,
live-rendered document rather than as separate source and preview panes?

## Findings adopted

- MarkText demonstrates the intended interaction: one distraction-free WYSIWYG surface, not a
  split editor/preview pane; ordered and unordered lists continue on Return.
- MarkEdit demonstrates that Markdown correctness needs a deliberately maintained editing model,
  rather than a handful of regex substitutions presented as a full renderer.
- Both projects are local-first Markdown editors under MIT, but their complete engines depend on
  web editing stacks (Muya/Electron and CodeMirror). Importing either wholesale would add a large
  runtime, third-party supply chain, and a non-native editing surface to Dayday.

## Dayday translation — replaced by owner decision

The owner selected MarkEdit on 2026-08-09. Dayday now uses the fixed macOS Sonoma-compatible
MarkEdit commit `85e670450c1081d4ff92b85ce7052278a8c5e93d` / v1.26.2. The complete repository is
retained as a pinned Git submodule so future decisions can inspect or adopt upstream features
without an unversioned download. The production reuse scope remains:

- `CoreEditor/` compiled as local WebKit resources, with Dayday Live Preview installed through
  MarkEdit's public extension API;
- `MarkEditCore/Sources/` and `MarkEditKit/Sources/` as the reviewed editor bridge.

The chosen snapshot is MIT licensed; its root `LICENSE` is included in the Dayday notice. The
snapshot is necessary because the maintained MarkEdit `main` package declares macOS 15, while
Dayday retains macOS 14 support. `MarkEditMac`, its preview extension and build tools remain in the
pinned submodule as source-only capabilities; Dayday does not activate their document model, file
URLs, scripts, updater, preview process or AI tools.

`CoreEditor/dist` was regenerated locally from this fixed source and copied into
`Sources/DaydayApp/Resources/MarkEdit`. Its `index.html` SHA-256 is
`2105c0902f9d3aae19597ccf62d09362531d9add6a96b01668bb2624c3de6ce9`.

Dayday owns the host view and only exposes a constrained local bridge for text, formatting,
selection, undo and composition. Journal persistence, attachments, location, history and the hard
work-report isolation boundary remain Dayday code. The compiled resource bundle is served through
a custom `WKURLSchemeHandler`, not an HTTP server; neither the bridge nor the editor performs
network loading.

## 2026-08-11 upstream follow-up

Current upstream MarkEdit has moved beyond the pinned Sonoma build and now publishes an official
extension ecosystem. Relevant primary sources reviewed on 2026-08-11 are:

- https://github.com/MarkEdit-app/MarkEdit/releases — current 1.33.x release line, including newer
  Writing Tools and IME work;
- https://github.com/MarkEdit-app/MarkEdit-ai-writer — MIT Apple Foundation Models writer requiring
  MarkEdit 1.27+ and macOS Tahoe with Apple Intelligence;
- https://github.com/MarkEdit-app/MarkEdit-mte — MIT structural Markdown table navigation and row,
  column, movement and alignment commands;
- https://github.com/MarkEdit-app/MarkEdit-prettier — MIT explicit document formatting command.

These are design and selective-backport candidates, not compatible binaries for Dayday's pinned
1.26.2/macOS 14 runtime. Dayday will implement the first journal AI backend through its existing
OpenAI-compatible provider and may add Foundation Models conditionally on supported systems.

The Dayday-specific `dayday-live-preview.js` extension is first-party code, not copied MarkEdit
source. It uses MarkEdit's extension surface to hide inactive syntax, render only
`dayday-attachment://` images from a private in-memory scheme and keep Markdown as the canonical
document. Source mode remains available for unsupported or advanced constructs.

## Explicitly not adopted in the current Sonoma editor runtime

- No Electron, Muya, external web host, user-authored script or Cloud sync is bundled.
- No automatic edit-history stream; realtime saving updates one private original.
- Newer MarkEdit extension binaries are not loaded into the older runtime. Journal AI is now an
  approved Dayday capability and must be integrated through a tested provider and derived-version
  workflow rather than by copying an incompatible extension bundle.
