# QueryPic Design System (v0.2 — Electric Violet & Cyber Cyan)

Hybrid UX per PRD §2: quick-search home → expanded workspace → preview modal → native player handoff.
Open `design.html` in a browser for the visual version.

## Tokens

### Color
| Token | Light | Dark | Use |
|---|---|---|---|
| `primary` | #6366F1 | #A5B4FC | Search CTA, active states |
| `accent` | #06B6D4 | #22D3EE | Privacy badge, Pro highlights |
| `bg` | #F8FAFC | #0B0F17 | Screen background |
| `surface` | #FFFFFF | #131924 | Cards, sheets, modals |
| `text` | #111418 | #F3F4F6 | Headings, body |
| `muted` | #6B7280 | #9CA3AF | Secondary text, placeholders |
| `border` | #E2E8F0 | #1E293B | Dividers, chip outlines |
| `success` | #16A34A | #22C55E | High match score (≥80) |
| `warning` | #D97706 | #F59E0B | Mid match (50–79), paused-indexing banner |
| `danger` | #DC2626 | #EF4444 | Errors, destructive actions |

### Typography (system fonts: SF Pro / Roboto)
| Style | Size / Weight | Use |
|---|---|---|
| Display | 28 / 700 | Home headline ("Find any photo or video…") |
| Title | 20 / 650 | Workspace title, sheet titles |
| Body | 15 / 400 | Results meta, settings |
| Caption | 12 / 500 | Match scores, timestamps, badges |
| Mono | 12 / 400 | Transcript snippets, debug |

### Shape & Spacing
* Radius: search bar 16, chips 999 (pill), cards 12, sheets/modals 20 (top), buttons 12.
* Spacing scale: 4 / 8 / 12 / 16 / 24 / 32. Grid gap 8, screen padding 16.
* Elevation: card `0 1px 2px rgba(0,0,0,.06)`, modal `0 12px 32px rgba(0,0,0,.18)`.

## Components

1. **Search bar** — 56px, surface fill, leading 🔍, trailing mic + clear. Placeholder: `Try "receipt from Home Depot"`.
2. **Filter chips** — pill, border default; active = tint bg #EEF2FF (light) + primary text (#6366F1 light / #A5B4FC dark). E.g. Receipts, Videos with Speech, Recent Sunset.
3. **Indexing banner** — info strip under search: progress bar + text `Indexing 1,240 of 5,000…`; paused variant (amber) with reason `Paused: battery <20%`.
4. **Privacy badge** — cyan accent pill (bg light #E0F7FD / dark rgba(34,211,238,.15), text #06B6D4 light / #22D3EE dark) with 🔒 `100% on-device · 0 bytes uploaded`.
5. **Result card** — 3-col grid thumbnail, duration/transcript icon overlay, match-score pill top-right (green ≥80 / amber 50–79 / gray <50).
6. **Preview modal** — large thumb, score + timestamp + transcript snippet, primary CTA `Open in native player`, secondary `Find Similar (Pro)`.
7. **Paywall sheet** — Free vs Pro table, Paystack Web Checkout CTA in beta (`Monthly` / `Yearly` buttons opening the live payment pages, license key emailed for Settings entry), stores note deferred to production.
8. **Buttons** — Primary (filled #6366F1 light / #A5B4FC dark with dark text #0B0F17, white text on light), Secondary (tinted #EEF2FF bg + #6366F1 text), Ghost. 48px min touch target.

## Screens (see HTML preview)
1. **Home / Quick Search** — headline, search bar, chips, privacy badge, indexing banner, starter grid.
2. **Expanded Workspace** — query + result count, filter row, 3-col grid with scores, transcript snippet on video cards.
3. **Preview + Paywall** — modal with timestamp seek CTA; Pro sheet for similarity / timed STT.

## Dark mode
Same tokens via `Dark` column; match pills keep hue, surfaces #131924 on background #0B0F17. Dark primary #A5B4FC, dark accent #22D3EE, dark border #1E293B.

## Accessibility
* Min contrast 4.5:1 body, 3:1 large text; scores never color-only (always show % number).
* 48px targets, dynamic type support, content descriptions on thumbnails ("Photo, receipt, 92% match").
