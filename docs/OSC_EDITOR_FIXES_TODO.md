# VoidLink OSC Editor / Streaming — Session Fixes & Pending TODO

_Last updated: 2026-06-01. Branch `my-build` (ahead of `origin/my-build`; these are NOT pushed)._

This file preserves the context of a long debugging session so work can resume after a context compaction. **All known items are now fixed (pending the user's on-device verify).** The two newest fixes — the tilt-vanish (obscure-alpha) `920f9bc2` and the iPad portrait toolbar overlap `d2fe06fa` — are at the top of the table below.

---

## ✅ Done this session (all Codex-reviewed)

Commits (newest → oldest), since `98662d07`:

| Commit | What |
|---|---|
| `d2fe06fa` | **Editor (iPad): fix portrait toolbar overlap at the STORYBOARD level (exact-fit stack).** Toolbar stack `YLK-IE-ajS` was width=830 while its six required-50pt items + spacing total only 650 → 180pt of ambiguous slack; plus a contradictory `EPu-dl-Tv8.centerX` pin on an arranged subview. That ambiguity is exactly what hid Save in the two runtime attempts. Fixed by exact-fit: spacing 70→40, width 830→500 (=6×50+5×40, zero slack), removed the centerX pin (centerY kept). Clears Exit by ≥57pt down to 744pt-wide portrait; every button keeps 50pt so Save is now deterministic. xmllint + Codex clean. **This replaces the runtime iPad path, which stays a no-op.** Side effect: landscape row is more compact (500 vs 830). |
| `920f9bc2` | **Editor: never obscure widgets while editing (fix tilt-vanish — the 'reappeared' one).** `OnScreenWidgetView.obscuredByAlpha` is a shared static set by streaming (StreamView reload / setWidgetsHidden); the editor never reset it, so entering with the OSC hidden left it true, and `touchesCancelled` (a device tilt cancels the active touch mid-drag) + `touchesEnded` dropped the widget to alpha 0.02 → "vanished". Gated both 0.02 drops on `!OnScreenWidgetView.editMode`; static value left untouched (streaming keeps its state). Distinct path from `a1d952fe` (which *removed* an unsaved widget; this only fades alpha), hence "reappeared". Codex clean. |
| `796c7a6c` | **Editor: stop touching the iPad toolbar (restore the Save button).** Reverted the iPad-side adaptive resize — it kept hiding the Save button. iPad now uses its original storyboard toolbar layout. (Supersedes the iPad parts of `24d51c01`/`c775d1c1`.) |
| `24d51c01` | (superseded) iPad overlap attempt #2 — shrink the iPad stack's own width + spacing. **Hid the Save button**, reverted by `796c7a6c`. |
| `c775d1c1` | (superseded) Gate adaptive toolbar to iPhone (attempt #1 to stop iPad Save vanishing). |
| `186271ab` | **Stream: resync widget obscure state on reload (fix tap-to-disappear).** During streaming, tapping an OSC widget could make it vanish; fixed by re-syncing `OnScreenWidgetView.obscuredByAlpha` + widget alpha to the legacy OSC obscure state at the end of `StreamView.reloadOnScreenWidgetViews`. |
| `7975c863` | **Editor: rotation lock works via the root VC (SWRevealViewController).** See "Orientation authority" note below. |
| `bbfd7276` | Editor: adaptive toolbar row (iPhone). Fixes iPhone portrait overlap. (iPad part later disabled.) |
| `903b6c54` | Editor: move rotation-lock button into the toolbar (top-trailing) + StreamFrame coordination. |
| `fb1dd396` | Editor: stop a widget drag from hijacking legacy OSC layers (dpad/select followed the finger) + initial floating lock button. |
| `a1d952fe` | Fix: a newly-added OSC widget vanished on a slight tilt in the layout editor (stuck `viewWillBeResized` → no-save reload). |

**User has confirmed working:** rotation lock, drag-hijack fix, widget-tap-disappear fix, iPhone behaviour. **User is on iPad.**

---

## ✅ RESOLVED — iPad portrait toolbar overlap (fixed in `d2fe06fa`)

> **Done** via the storyboard exact-fit approach (spacing 70→40, width 830→500, removed the contradictory Trash `centerX` pin `9ua-n0-eG4`). xmllint + Codex clean. Pending the user's on-device verify that 返回/撤销 no longer overlap **and the Save button is present**. If anything is off, it's a clean single-commit revert. The original analysis below is kept for reference — and note the hard rule (still true): do NOT reshape the iPad toolbar at runtime.

**Symptom (was):** In the OSC layout editor on **iPad, portrait**, the top toolbar's leftmost button (Undo / 撤销) overlaps the Exit / back button (返回). User wants it fixed.

**Hard constraint learned the hard way:** **DO NOT reshape the iPad toolbar at runtime.** Two runtime attempts (resizing the buttons, then resizing the stack's own width) both **hid the Save button**. iPad runtime resize is now disabled (`796c7a6c`) — the iPad branch in `osc_layoutAdaptiveToolbarIfNeeded` is a bare `return;`. Leave it that way.

**Fix the iPad overlap at the STORYBOARD level instead** (`VoidLink/Base.lproj/iPad.storyboard`), carefully, and have the user rebuild + verify.

### Why runtime failed / the iPad toolbar structure
The iPad toolbar row is the stack **`YLK-IE-ajS`** (`iPad.storyboard` ~line 1282), outlet `toolbarStackView`. It is unusual / ambiguous:
- It has a **fixed `width = 830` constraint** (`zzS-yc-O4H`, line 1402) **and** `centerX` to its container (`xm7-a0-8G7`, line 1449). In iPad portrait (~768–834pt) the centered 830-wide row overflows and its left edge collides with the Exit button. **This 830 fixed width is the root cause of the overlap.**
- Arranged subviews (6): Undo `F7X-l4-cl3`, Load `OId-gk-Wkg`, **Save `uda-zt-xrG`** (outlet `saveButton`, ~line 1319), a **nested Trash sub-stack `EPu-dl-Tv8`** wrapping the Trash button, Add `fKN-ja-TRi`, Edit. Each item is 50pt wide.
- The nested wrapper `EPu-dl-Tv8` is **pinned to the row centre** (`centerX`/`centerY` to `YLK-IE-ajS`, lines 1400–1401) instead of flowing — and many of these stacks are marked `ambiguous="YES"`. Touching the stack width at runtime makes this ambiguous layout drop the Save button.
- Exit/back button: absolute, pinned leading (~x18, 50pt) in the toolbar container. The rotation-lock button (added in code) is pinned trailing (~ -18, 50pt) on both idioms.

### Recommended storyboard fix (to try, then have user rebuild+test)
1. **Remove/relax the `width = 830` constraint** on `YLK-IE-ajS` and instead pin it so it can't overflow: e.g. `leading >= container.leading + ~76` and `trailing <= container.trailing - ~76` (clearing the Exit on the left and the lock on the right), keeping `centerX`. With six 50pt buttons (300pt) the content fits portrait easily once it's no longer forced to 830.
2. Likely also **fix the ambiguous nested Trash wrapper** (`EPu-dl-Tv8` centerX-pinned) so the row flows normally — that ambiguity is why runtime width changes mangled it.
3. Keep changes minimal; a malformed storyboard prevents the app from launching, and **this cannot be compiled/tested locally** — the user rebuilds and verifies on-device.

(iPhone uses a different flat toolbar — stack `4he-pe-kYB`, fixed width 750 — and its adaptive fit in `osc_layoutAdaptiveToolbarIfNeeded` is unchanged and working. Don't touch the iPhone path.)

---

## Key files & symbols
- `VoidLink/ViewControllers/CustomOSCViewControl/LayoutOnScreenControlsViewController.{h,m}` — the layout EDITOR. Adaptive toolbar = `osc_layoutAdaptiveToolbarIfNeeded` (called from `viewDidLayoutSubviews`; iPad early-returns). Helper `osc_setFixedDimension:ofView:to:`. Rotation-lock button = `osc_setupRotationLockButton`; lock state published to globals via `osc_publishRotationLockAndRefresh`.
- `VoidLink/ViewControllers/SWRevealViewController.m` — **root VC; authoritative for orientation.** `supportedInterfaceOrientations` (~815) reads `extern BOOL gOSCEditorRotationLocked` / `gOSCEditorLockedMask` (defined in the editor .m) so the editor's rotation lock actually works.
- `VoidLink/Input/StreamView.m` — runtime OSC. `reloadOnScreenWidgetViews` (~523) now re-syncs widget obscure state at its end. `setOscObscuredByAlpha:` / `isOscObscuredByAlpha` = the legacy-layer obscure state.
- `VoidLink/ViewControllers/StreamFrameViewController.m` — presents the editor `UIModalPresentationOverCurrentContext`. `setWidgetsHidden:` sets `OnScreenWidgetView.obscuredByAlpha`.
- `VoidLink/Input/OnScreenWidgetView.swift` — `static obscuredByAlpha`; touch handlers drop a widget to alpha 0.02 when obscured. `editMode` static.

## Architectural facts that cost iterations (keep in mind)
- **Orientation authority = `SWRevealViewController` (the storyboard's initial / root VC).** It returns its OWN mask (from the `unlockDisplayOrientation` setting) and does **not** delegate to children, so orientation overrides on the editor or StreamFrame are ignored. AppDelegate's `application:supportedInterfaceOrientationsForWindow:` is commented out.
- **Two obscure states must stay in lockstep:** the legacy OSC layers' (`onScreenControls`) and the widget static (`OnScreenWidgetView.obscuredByAlpha`). A reload that rebuilds widgets at full alpha but leaves the static stale-true makes a tap drop the widget to 0.02 ("disappears").
- **iPad toolbar ≠ iPhone toolbar** (nested + ambiguous vs flat). Idiom-specific handling is required; never assume one structure.
- Cannot build/test locally — every fix is reasoned + Codex-reviewed, then the user rebuilds on-device and verifies.
