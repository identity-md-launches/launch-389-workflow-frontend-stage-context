# Whale Tax design

## Overview

A single-page Sepolia trading experiment for people exploring the relationship between swap size, price movement and hook fees. The interface uses warm paper, dark green type, generous section spacing, a direct numeric hierarchy and one outlined trading card. Pool context and the fee curve precede the transaction controls in DOM order; details and less frequent wallet tools use native disclosures.

This document lives under `docs/` because the overriding task scope prohibits root `DESIGN.md`. Source of truth: `web/src/styles.css` and the implemented `Whale`, `Curve` and page patterns in `web/src/App.tsx`.

## Colors

All colors use sRGB hex values; this is a single light theme. Core semantic tokens in `:root`:

| Token | Value | Use |
| --- | --- | --- |
| `--paper` | `#f5f4ed` | Page and amount-field background |
| `--surface` | `#fffef9` | Card, inputs, outlined buttons |
| `--ink` | `#163e38` | Main text, chart stroke, primary action fill |
| `--muted` | `#586c63` | Secondary descriptions and labels |
| `--line` | `#c9d1c3` | Structural dividers and card boundaries |
| `--tint` | `#e7eedf` | Segmented-control track, output surface, hover |
| `--warn` | `#794214` | Price-limit explanation, warning copy, preview marker |
| `--error` | `#9c3026` | Failure text and borders |
| `--focus` | `#175eac` | Three-pixel keyboard focus perimeter |

The curve fill is `#e1ebcb`; the selected simulation marker has a `#fff3d8` fill. Warning/error messages also use text, not color alone. Filled emphasis follows the current next action: preview, connection, approval or swap. Measurements for actual rendered pairs are in `evidence/browser.json`; these do not imply every possible native wallet or operating-system theme was tested.

## Typography

The CSS requests `Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`. There are no downloaded fonts or external font requests; the installed system face is intentional and varies by OS. `font-synthesis: none` prevents invented faces. Requested weights range from 400 to 750; exact available weights depend on that system font.

Body starts at 16px with 1.5 line height. Dense UI copy uses 12–15px; inputs remain at least 16px, with the swap amount at 32px. The main heading scales from 40px to 72px, at 1.07 line height and −0.05em tracking, with a 15ch measure and balanced wrapping. Section headings are approximately 21px with 1.25 line height. Eyebrows use uppercase CSS, 12px and 0.12em tracking. Price and monetary values use tabular numerals. Live price scales between about 37px and 56px. Long contract identifiers wrap anywhere; shortened wallet labels retain the full address in wallet/RPC state and deployed addresses are fully displayed in the disclosure.

The SVG chart has a 540×235 viewBox. Annotation sizes increase at narrow breakpoints so axes remain legible. Its title/description and nearby prose provide the same fee checkpoints in text. Text remains selectable. Form labels persist when inputs are filled.

## Layout

The shared page container caps at 1,240px with 40px inline padding, reducing to 28px, 20px and 16px. The header is a flex row; at the narrowest width it wraps the wallet controls into their own row. Most groups use 8–16px within and 24–58px between sections. Actions have at least 44px height, with full-width primary actions at 48px.

The main workspace has two unequal columns with a 58px gap. At 65rem the gap shrinks to 32px and metrics reorganize. At 47rem the workspace, lower sections and technical details become single-column. At 24rem metrics stack further and the header wraps. DOM reading order is retained on mobile. The experiment number is decorative and omitted at small widths; required controls remain in normal document flow.

Fee tables scroll within a named keyboard-focusable region when values need more width, with a visible scroll hint. Address links wrap; the whole page does not scroll horizontally at the checked 1440, 820, 390 and 320px widths. 200% text enlargement was tested separately from native browser zoom.

## Elevation & Depth

The interface is mostly flat. `.card` uses one 1px structural border and a very light `0 6px 18px #18362f06` shadow. The selected direction has a subtle `0 1px 3px #163e380c` shadow and a visible boundary. There are no modal overlays, floating action bars, entrance animations or background video.

## Shapes

`--radius` is 18px for the trade card. Buttons use 9px; fields use 8px; amount/output fields and segmented tracks use 10px. Fee-cap badges are pill-shaped (20px radius). Dots indicate live/connecting state alongside readable labels. The whale mark is a small decorative currentColor SVG made in source; no image generation or raster asset is required.

## Components

- `Whale` (`App.tsx`): decorative brand mark, hidden from assistive technology. The adjacent text is the linked name.
- `Curve({move})` (`App.tsx`): SVG fee curve and an optional preview marker. The values follow the source-constant formula; live contract checkpoints are checked before transaction readiness.
- `.primary`, `.outline`, `.full`: primary/secondary button patterns; native disabled states, 3px `:focus-visible` outline, pointer hover guarded by `@media (hover:hover)`. The page has one filled next action at a time.
- `.segmented`: two ordinary buttons with `aria-pressed`, not a custom keyboard tab widget. Both are reachable with Tab and operate with Enter/Space.
- `.amount-box`, `.tolerance`, `.output`, `.quote-details`: the swap input and preview pattern. Persistent labels, decimal keyboards, units, fee distinction, expiry and price-limit explanation remain visible. Invalid amounts focus the input and connect to the error message.
- `.notice`, `.feedback`: errors use alerts; transaction progress uses a stable polite status region. Status text and explorer links remain until superseded. Read errors keep actions gated and expose Refresh where a configuration exists.
- Native `details/summary`: fee burning and technical/wallet tools. No custom focus trapping; browser keyboard disclosure semantics are retained.
- `.fee-table`, `.events`, `.empty`: compact accounting, latest activity and readable empty/error states. Empty activity explicitly refers to the bounded recent-block window.

The app does not implement motion. Reduced-motion mode therefore has no animation to suppress. Forced-colors focus uses the system Highlight color; native form controls retain platform behavior. No dark-theme, localization or screen-reader certification is implied.

## Do's and Don'ts

- Reuse the page container, existing semantic color tokens, labels, notices and button patterns for related surfaces.
- Keep the fee on output distinct from the pool LP fee on input. Describe actual router guarantees precisely.
- Keep one filled next action per flow; put supporting actions in outlined controls.
- Keep contract identifiers readable and maintain units for every balance/amount. Never turn unknown live values into zero.
- Keep transaction prerequisites enforced in both UI and signing code. Cosmetic disabled styling alone is insufficient.
- Do not add an independent deployment address map, externally loaded fonts, animated market decoration or invented analytics.

Design guidance: Jakub Krehel's Better Interface, MIT, pinned commit `267330e1adfc66a718fb65fa6918c1f06d0a689e`. Documentation method: Paul Bakaus's Impeccable, Apache-2.0, pinned commit `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8`. The supplied guides were applied as reference material; this document records the final implementation. Source links: [Better Interface](https://github.com/jakubkrehel/skills/tree/267330e1adfc66a718fb65fa6918c1f06d0a689e/skills/better-interface), [Impeccable document method](https://github.com/pbakaus/impeccable/blob/9d715cc4f5564a990ca8345abfdd5df6dc9b41c8/skill/reference/document.md).
