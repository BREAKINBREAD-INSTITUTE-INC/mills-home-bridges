# MILLS OS TV — Design Rules

The locked foundation. Sizes, colors, and core decisions do **not** change build to build.
Everything new is built on top of these, using the same tokens and components, so the system
grows without drifting. If a change would break a rule here, it's a deliberate version bump,
not a one-off tweak.

Reference mockup: `mills-tv-fullconcept.html` (the five-view concept). This doc describes it.

---

## 1. Principles (never break these)

1. **The TV reads; the phone approves.** The TV shows status and what needs you. Reviewing,
   approving, and changing settings happen on a phone or computer. No destructive controls on the TV.
2. **Glanceable from 10 feet.** One main thing per screen that the eye finds first, then support.
3. **Honest data only.** Every reading is labeled and time-stamped. Show "unknown / offline /
   stale" plainly. Never show a static green dot that can't prove it's true. The number and its
   visual (ring, bar) come from the same source.
4. **Calm and dark.** Deep background, one accent at a time, lots of breathing room.
5. **GPU-light for the VH2.** Gradients, strokes, and at most one slow animation. No video
   wallpaper, no blur, no animated shadows, no full-screen transitions.
6. **Use each app's own logo**, never a redrawn brand mark. Tiles frame the app's real icon.

---

## 2. Locked tokens

### Palette
| Token | Hex | Use |
|---|---|---|
| ink (bg) | `#0B0F14` / page `#07090D` | base background |
| panel | `#121A23` / card `#0D141C` | card surfaces |
| edge | `#1C2733` | borders, 1px |
| gold | `#E0A526` | MILLS OS identity, selected view, focus, attention |
| teal | `#2BB3A3` | healthy / active / on |
| red | `#CF5B5B` | problem / offline |
| text | `#F2F4F7` | primary text |
| dim | `#9AA6B2` | secondary text; `#8794a0` for timestamps (min readable) |

Do not introduce new accent hues. A chart that needs more than one data color uses one gold
ramp (light→dark), not a rainbow.

### Font
**Outfit** (variable). Weights: 300 big numerals, 400 body, 500 values, 600 labels/titles, 700 wordmark.

### Type scale — LOCKED (this is the sizing we agreed on)
Expressed as `vw` against the 16:9 frame in the mockup, with the px equivalent on a real
1920×1080 canvas. A real build uses the px column; the mockup uses vw. **Do not enlarge these.**

| Role | mockup | 1920×1080 |
|---|---|---|
| Clock (Home) | 4vw | ~77px |
| Hero value (indoor temp standalone) | 5vw | ~96px |
| Section value (storage %, budget total) | 2.2–2.4vw | ~42–46px |
| Compact hero (House temp in strip) | 3.2vw | ~61px |
| Card headline (AI summary) | 1.5vw | ~29px |
| Agent name | 0.92vw | ~18px |
| Nav destination | 1vw | ~19px |
| Wordmark | 1.05vw | ~20px |
| Body / rows / task text | 0.82–0.86vw | ~16px |
| Label (k) / chip | 0.72–0.74vw | ~14px |
| Timestamp / note | 0.68–0.72vw | ~13–14px |

### Spacing & shape
- Safe margin inside the frame: **4%** (≈45px at 1080p).
- Card radius **14px**, tile radius **10px**, chips/bars **999px** (pill).
- Card padding **1.4vw**; gaps between cards **1.1vw**.
- Card background: `linear-gradient(180deg, rgba(18,26,35,.72), rgba(11,15,20,.72))`, 1px edge.

---

## 3. Color meaning — one job per place

Gold does three things, each a **different shape** so they never collide:
- **Pill** (filled gold) = the view you're on (nav).
- **Ring** (gold outline + slight lift) = where the cursor/focus is. Only one on screen.
- **Left-bar + one pulsing dot** = something that needs you (attention). Never a ring.

Other colors:
- **Teal** = healthy, active, on. **Red** = problem/offline (never used for focus or selection).
- **Dim gray** = idle, unknown, secondary.
- **Status is always a dot + a word.** Never color alone.

---

## 4. Focus & remote (D-pad) model

- **Nav row:** Left/Right moves between views, OK switches, Down drops into content.
- **Content:** Up from the top row returns to nav (lands on the current view). Left/Right within a
  row, Up/Down between rows.
- **Back:** content → nav; nav → Home; Home → nothing (never exit the launcher).
- **Entering a view:** focus starts on its most important item (Mission Control → Waiting; House →
  temp; System → Storage), not top-left.
- **Returning from an app:** focus restores to the last-used tile.
- One focused item at a time. Incoming data never steals focus.

---

## 5. Components (reuse, don't reinvent)

- **Card** `.c` — the base surface for everything.
- **Chip** `.chip` + `.ok/.warn/.bad/.idle` — a status pill: colored dot + short label.
- **Status dot** — 0.5vw circle, color = state.
- **Ring** — SVG donut for a single percentage; the number sits beside or inside it, from the same value.
- **Budget bar** `.brow` — label · track · amount; one gold fill, scaled to the largest item in the set.
- **Agent card** `.ag` — name + state chip, task line, elapsed/last-update.
- **App tile** — 16:10, the app's own banner/logo filling it, label under; gold ring on focus.
- **Nav** — destinations as pills; current = filled gold.

New features use these. A new metric is a card with a chip; a new breakdown is budget bars; a new
status is a dot + word. No new component unless nothing here fits.

---

## 6. The five views (purpose is fixed; contents can grow)

| View | Answers | Holds |
|---|---|---|
| **Home** | What matters right now? | Clock, greeting, weather; AI summary; house temp; apps; small network line |
| **Mission Control** | What is my AI system doing? | Agents + states, "Waiting for JJ", machines, usage, recent results |
| **House** | What's happening at home? | Nest (temp/target/activity/mode/humidity); monthly housing budget breakdown |
| **Network** | How healthy is the network? | Internet, protection (ad-block/DNS/VPN), UniFi gateway, key devices online |
| **System** | Is the TV itself healthy? | Storage, privacy, performance, display & links |

Add new cards inside the view whose question they answer. A new view is a last resort and must
answer a question the five don't.

### Agent states (consistent everywhere)
`Working · Waiting · Ready · Queued · Scheduled · Paused · Blocked · Offline · Unknown`.
The Home summary is derived from these same states — they must always agree.

---

## 7. Data honesty rules

- Label every reading (indoor vs outdoor, capability vs current output).
- Show "updated Xs ago" on anything live. A separate "monitor connected" indicator says whether
  the feed itself is alive, apart from whether the thing is healthy.
- Stale data visibly greys out; it does not keep showing green.
- A setting, a recently-checked value, and actually-observed traffic are three different claims — don't blur them.
- Mockups carry a "Concept · sample readings" tag until wired to real data.

---

## 8. Don'ts

- Don't enlarge the type scale in §2.
- No pie/donut for comparing parts (use bars); no dual-axis charts; no rainbow palettes.
- No video wallpaper, blur, animated shadows, or view-switch animations on the VH2.
- No redrawn brand logos; use the app's own icon.
- No "live" label for something only checked for reachability — say "online".
- No control that changes a real setting from the TV.

---

## 9. How we grow it

1. New idea → pick the view whose question it answers.
2. Build it from an existing component in §5 with the tokens in §2.
3. Keep the sizes in §2. If it doesn't fit, shorten the panel or move it, don't shrink-to-fit or blow it up.
4. Label and time-stamp it (§7).
5. If it truly needs something new, add it here first as a rule, then build.

---

## 10. Build staging

- **Ships first (data the TV + UniFi already expose):** Home, Network, System.
- **Needs the always-on feed (MissionControl host):** Mission Control, the housing budget.
- **Needs a confirmed Nest model over Matter:** House thermostat.
- The TV is a viewer. Integration credentials and controls live on the backend and the phone.

---

*v1 — foundation locked. Revise this doc on purpose, with a version bump, never by drift.*
