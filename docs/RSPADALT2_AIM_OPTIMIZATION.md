# RSPADALT2 Aim Optimization Notes

Last updated: 2026-06-12

This document records the current aiming-feel goal, the tested implementation directions, the latest technical model, and the next optimization path for `RSPADALT2`.

## Task Goal

`RSPADALT2` is an experimental right-stick on-screen control for shooter aiming in VoidLink Retouch. The target feel is closer to a mobile shooter touch aim surface than to a virtual joystick.

Key shooter-feel requirements:

- Finger travel distance should be the main input. If the finger moves farther, the crosshair should move farther.
- The same finger travel distance should not produce very different aim distance just because the finger moved faster.
- Very small finger movements, even a few screen pixels, should produce visible and fine crosshair changes.
- Small movement must not be dead, jumpy, or gated behind a large threshold.
- Large movement must still cover enough distance without relying on speed-only acceleration.
- Direction changes while the finger stays down should respond immediately, including reversing direction.
- Output should feel smooth and slightly damped, matching display refresh rather than raw, uneven touch event cadence.
- Stop behavior should not drift: when the finger stops and the aim budget is drained, the right stick should clear.

The important constraint is that VoidLink is sending right-stick input to the streamed game. Unlike a native mobile shooter camera input, the game may apply right-stick dead zones. That makes micro-aim harder: a mathematically tiny right-stick output may be ignored by the game, so the implementation needs careful dead-zone compensation without creating a visible jump.

## Tested Directions

### 1. Add a dedicated aim pad command

Commits:

- `3c43ab5a Add RSPADALT2 aim stick pad`
- `dfdbd56e Fix RSPADALT2 aim response mapping`
- `dba38d54 Make RSPADALT2 use RSVPAD baseline response`

Direction:

- Added `RSPADALT2` as a separate OSC touchpad command, independent from the existing `RSPADALT`.
- Initially explored delta/velocity style mappings and `RSVPAD`-like behavior.

Result:

- Early versions felt poor: large finger travel moved the crosshair only slightly, and small or slow movement often did nothing.
- Main lesson: per-frame tiny deltas are too weak after right-stick/game dead-zone handling. The control needs either accumulated displacement or an accumulated aim budget.

### 2. Cumulative anchor model

Commit:

- `1a762af4 Rework RSPADALT2 aim pad response`

Direction:

- On touch down, store an anchor.
- While moving, calculate `currentLocation - anchor`.
- Convert that accumulated offset into right-stick output.
- When the finger stops for about `80-100ms`, clear the right stick and reset the anchor to the current touch position.

Result:

- Wei confirmed this version was "normal" compared with previous broken attempts.
- It validated that accumulated movement distance matters.
- It still feels joystick-like: the crosshair is driven by displacement from an anchor, so direction changes and no-lift reverse movement do not feel like a direct touch/trackpad surface.

Technical notes:

- This remains the known baseline when `Relative Aim` is off.
- It still uses the classic controls: `Stick Range`, `Stick Curve`, and `Max Output`.

### 3. Aim-specific cumulative response

Commit:

- `77a0e701 Add aim-specific response model to RSPADALT2`

Direction:

- Kept the cumulative anchor model as the base.
- Added fast-swipe velocity boost, radial dead-zone compensation, dynamic smoothing, stop-zero behavior, and aim-specific defaults.

Defaults at that point:

- `Stick Range 42`
- `Stick Curve 1.18`
- `Max Output 0.92`

Result:

- Improved the known cumulative model but still did not become shooter-style direct follow.
- The model still fundamentally depended on anchor displacement and could feel close to `RSPADALT`, with the useful difference that finger stop clears aim.

### 4. Switchable Relative Aim experiment

Commit:

- `25db3c16 Add switchable relative aim mode for RSPADALT2`

Direction:

- Added a `Relative Aim` switch to the `RSPADALT2` parameter panel.
- Off: keep the confirmed cumulative anchor model.
- On: test a relative movement model where no-lift direction changes can drive the crosshair directly.

Result:

- This was the right product structure: it preserves the baseline while allowing risky aim experiments in the same control.
- Later iterations focus on the `Relative Aim` branch.

### 5. Pure per-frame delta model

Commit:

- `36ccb7a5 Tune RSPADALT2 relative aim for touchpad feel`

Direction:

- Tried mapping each touch-move delta directly to right-stick output.
- Removed hard center dead-zone behavior.
- Added jitter filtering, low-speed smoothing, and fast-swipe acceleration.

Result:

- Worse than the cumulative baseline.
- Movement distance was too short and felt close to the earliest broken versions.

Technical lesson:

- A single touch event's delta is often too small after conversion to right-stick output.
- Touch event cadence is also uneven, so "send only when touchMoved arrives" can feel like stutter or broken continuity.

### 6. Velocity-based relative model

Commit:

- `c7d13353 Use velocity-based relative aim response`

Direction:

- Used `delta / elapsed` as the primary signal.
- Added a light soft floor for game dead-zone compensation, fast movement acceleration, and decay for tiny/noisy movement.

Result:

- Still did not solve the feel.
- Movement distance remained too small, and the center-dead-zone feeling remained.

Technical lesson:

- Velocity can make fast movement respond, but it makes the same finger distance produce different crosshair travel depending on speed.
- That is not a good baseline for mobile shooter-style aiming.

### 7. Persistence fix for tuning

Commit:

- `f7c2e38f Fix RSPADALT2 curve tuning persistence`

Direction:

- Fixed a settings persistence bug where manually saved `Stick Curve` values could be treated as legacy defaults and reset.

Result:

- Important infrastructure fix for testing. Parameter changes now persist reliably.

### 8. Trackpad integrator v3

Commit:

- `c119a7a4 Implement RSPADALT2 relative aim v3 trackpad integrator`

Direction:

- Touch deltas feed a signed aim/displacement budget.
- A `CADisplayLink` drains that budget over multiple frames into right-stick output.
- Opposite-direction input cancels or reverses existing budget quickly.
- Tiny deltas keep fractional residuals.
- Fast swipes get nonlinear gain and more coverage.
- `Stick Curve` participates in output shaping.

Result:

- Mechanically closer to a trackpad than the previous delta/velocity attempts.
- Later feedback clarified that the diagnosis "small movement is too sensitive" was inaccurate. The real issue was:
  - tiny movement did not move the crosshair,
  - slightly larger movement jumped,
  - larger movement traveled too far.

Technical lesson:

- Speed boost made large movement look effective, but it also broke distance consistency.
- `Stick Curve` can worsen micro-aim because it suppresses small output that may already be below the game's right-stick dead zone.
- The control needs linear distance mapping first, then careful dead-zone compensation.

### 9. UI/default rename attempt and rollback

Commits:

- `cd09de01 Tune RSPADALT2 trackpad aim defaults`
- `0b308a58 Revert "Tune RSPADALT2 trackpad aim defaults"`

Direction:

- Renamed `Stick Range / Stick Curve / Max Output` to `Aim Range / Micro Curve / Peak Output` under `Relative Aim`.
- Tuned defaults and added migration logic.

Result:

- Wei reported that version felt strange.
- The rollback restored the previous v3 behavior.

Technical lesson:

- Merely renaming joystick parameters is misleading.
- `Relative Aim` needs trackpad-specific parameters that map to actual algorithm concepts.

### 10. Lift-off coast + frame-synced injection (2026-06-12)

Diagnosis that motivated this round (from a quantitative pass over the v3 linear
integrator with Wei's "still shaky/jumpy, fast swipes feel short" feedback):

- **Fast swipes lost most of their input.** Steady-state full deflection is
  reached at only ~250pt/s finger speed (gain 2.8). Anything faster floods the
  impulse pool, which was (a) capped at `stickInputScale * 0.42` with overflow
  discarded, and (b) **hard-cleared on lift-off**. A 200pt swipe at 1000pt/s
  kept only ~25% of its travel; the same 200pt moved slowly kept 100%. That
  directly violates the distance-consistency goal and explains "fast aim turns
  need several swipes but slow tracking looks fine".
- **The 0.42s tail caused overshoot-correct-jump loops.** With the finger held
  after a fast swipe the pool kept draining at full deflection for up to 0.42s.
  The correction then tripped the reverse brake (`alignment < 0.65`, i.e. any
  course change beyond ~50°), which zeroed the pool **and** the output filter
  state, so the next frame bypassed smoothing — a one-frame stick snap. Slow
  precision movement also tripped this constantly because touch direction noise
  at low speeds easily exceeds 50°. That is the "shaky/jumpy but the trail looks
  continuous" feel: velocity discontinuities, not position jumps.
- **Touch-clock injection rippled against the display-link clock.** Each touch
  event bumped the pool by ~20% (60Hz events, tau 75ms) and the display link
  sampled that sawtooth out of phase, producing a beat-frequency wobble in the
  stick output. The fixed EMA (alpha 0.86 per frame ≈ 8ms time constant) was
  too weak to filter it.

Direction implemented (P0 + P1):

- **Frame-synchronized injection.** `touchesMoved` only accumulates into
  `aimTrackpadPendingDelta`; the display link consumes the whole batch once per
  frame (`injectPendingAimDelta`). Injection and drain now share one clock, so
  the sawtooth/beat ripple is gone at the source.
- **Lift-off coast.** `touchesEnded` no longer clears the pool while the
  relative-aim display link is running; the remaining budget keeps draining
  after the finger lifts (trackpad-momentum semantics). The display-link guard
  no longer requires an active touch. Fast-swipe travel realization goes from
  ~25% to ~78% in the 200pt @ 1000pt/s case (the rest is the pool cap, which is
  the deliberate flick-coverage limit).
- **Press-to-stop.** While the finger rests on the pad with no effective
  injection for `0.07s`, the pool decays by `exp(-dt / 0.05)` per frame, so the
  crosshair settles under a held finger (~0.1-0.17s) instead of drifting
  through the stored budget. Skipped after lift-off so coast still completes.
- **Tap-to-stop.** A touch that lands while coasting and ends within the 8pt
  stationary slop hard-stops the pool — same muscle memory as tapping a
  trackpad to kill momentum. The consumed tap also resets the double-tap clock
  so stop-then-swipe within 0.2s cannot fire the R3 stick-click combo.
- **Stroke chaining.** A touch that lands while coasting keeps the pool, the
  display link, and the output-filter state, so rapid repeated swipes (turn
  fast by chaining strokes) blend instead of restarting from zero each time.
- **Reverse brake redesign.** Only a genuine reversal (`alignment < -0.25`,
  ~104°+) clears the old pool. Oblique course changes merge through vector
  addition. The brake no longer resets the output filter, so direction flips
  transition through the fast reverse tau instead of snapping in one frame.
- **dt-aware output smoothing.** `alpha = 1 - exp(-dt / tau)` with
  `tau = 0.020s` forward and `0.008s` on reversal — frame-rate independent,
  stronger ripple rejection than the old fixed alpha, still fast on flips.

Review notes (adversarial pass, 2026-06-12):

- Fixed before commit: the tap-to-stop tap used to count as the first half of
  a double tap, so stop-then-touch within 0.2s sent R3 to the game.
- Known and accepted: combo-command widgets (e.g. `A-RSPADALT2`) enable
  multi-touch, where a second finger can clobber the per-touch tap/coast flags
  (exotic config; touchpad widgets keep multi-touch disabled). If the app
  backgrounds mid-coast the host keeps the last stick value until the display
  link resumes and the pool drains (bounded, self-healing, worst case ~1.1s).
  Extremely slow drags (<~0.4pt/s) can poke the press-to-stop decay between
  injections; below the noise floor in practice.

## Previous Version Direction (superseded by 10)

Commit:

- `0901448a Make RSPADALT2 relative aim linear`

Latest `RSPADALT2 + Relative Aim` direction:

- Remove speed boost from the shooter baseline.
- Bind input primarily to finger travel distance.
- Map touch delta linearly into an aim budget.
- Keep fractional residuals so tiny movement is not thrown away.
- Bypass `Stick Curve` in `Relative Aim`.
- Add explicit right-stick dead-zone compensation.
- Use `CADisplayLink` to drain the aim budget smoothly.
- Keep direction reversal responsive by braking old budget when new movement disagrees strongly.
- Keep a peak output cap for large movement safety.

Relevant implementation files:

- `VoidLink/Input/OnScreenWidgetView.swift`
- `VoidLink/Input/CustomOSC/OnScreenButtonState.h`
- `VoidLink/Input/CustomOSC/OnScreenButtonState.m`
- `VoidLink/Input/CustomOSC/OSCProfilesManager.m`
- `VoidLink/Input/StreamView.m`
- `VoidLink/ViewControllers/CustomOSCViewControl/LayoutOnScreenControlsViewController.m`

Current exposed `Relative Aim` parameters (code defaults as of 2026-06-12):

- `Trackpad Gain`, default `2.8`, clamp `0.5...10.0`
- `Deadzone`, default `0` (zero-deadzone host setup), clamp `0.0...0.35`
- `Response Time`, default `0.075s`, clamp `0.030...0.140s`
- `Peak Output`, default `0.92`, clamp `0.20...1.00`

Current internal constants:

- `aimTrackpadNoiseDeadzone = 0.03`
- `aimTrackpadReferenceResponseTime = 0.06`
- `aimTrackpadReverseAlignment = -0.25`
- `aimTrackpadMaxImpulseTime = 0.42`
- `aimTrackpadOutputSmoothingTau = 0.020`
- `aimTrackpadOutputReverseTau = 0.008`
- `aimTrackpadStopThreshold = 0.003`
- `aimTrackpadStillHoldDelay = 0.07`
- `aimTrackpadStillDecayTau = 0.05`

Current data flow in `Relative Aim` (after direction 10):

1. `touchesMoved` computes the finger delta, multiplies by aim `SensitivityX/Y`, and only accumulates it into `aimTrackpadPendingDelta`. No host output happens on the touch clock.
2. Each `CADisplayLink` frame consumes the whole pending batch into the residual accumulator.
3. If residual magnitude is below `0.03pt`, it stays accumulated and nothing is injected this frame.
4. When residual passes the noise threshold it becomes a new aim impulse:
   - `newImpulse = delta * Trackpad Gain * 0.06`
5. If the new impulse genuinely reverses against the pending impulse (`alignment < -0.25`), the pending impulse is dropped; oblique changes merge via vector addition. The output filter state is never reset here.
6. The impulse budget is capped by `stickInputScale * 0.42`.
7. While the finger rests on the pad with no effective injection for `0.07s`, the pool decays by `exp(-dt / 0.05)` per frame (press-to-stop). This decay is skipped once the finger lifts.
8. Each frame computes `source = impulse / Response Time`, clamped to the stick range, converted to right-stick coordinates.
9. `Deadzone` compensation raises very small non-zero output above the game's right-stick dead zone (no-op at the current `0` default).
10. `Peak Output` caps the right-stick magnitude.
11. Output smoothing uses `alpha = 1 - exp(-dt / tau)`, `tau = 0.020s` normally and `0.008s` when the new target reverses against the last output.
12. The frame drains budget by `drain = source * dt`.
13. When the remaining impulse drops below the stop threshold, the display link stops and the right stick is cleared.
14. On lift-off the pool is **not** cleared: the display link keeps draining it (coast). A stationary tap during coast stops it immediately; a touch-down that starts moving chains into the coasting budget.

## How To Tune The Latest Version

Recommended tuning order (zero-deadzone host, defaults Gain 2.8 / Deadzone 0 / Response 0.075):

1. Expand dynamic range on the host first (biggest lever, no code).
   - Raise the in-game right-stick sensitivity (1.5-2x) and pick a linear
     response curve if the game offers one, then lower `Trackpad Gain`
     proportionally. Full deflection currently maps to only ~250pt/s finger
     speed at Gain 2.8; halving gain after doubling game sensitivity doubles
     the speed range before saturation, which is what makes fast swipes both
     cover distance and stop cleanly.

2. Tune `Trackpad Gain`.
   - Too sensitive overall: lower toward `2.2-2.6`.
   - Large movement too short even after step 1: raise toward `3.2-3.6`.

3. Tune `Response Time`.
   - Choppy / broken continuity: raise toward `0.085-0.095s`.
   - Laggy or floaty: lower toward `0.050-0.060s` (frame-synced injection
     keeps this stable where the old event-clock injection stuttered).

4. Tune `Peak Output` last.
   - Large movement too violent: lower to `0.82-0.88`.
   - Still cannot cover distance: raise to `1.00`.

5. `Deadzone` stays `0` for a zero-deadzone host. Only raise it (`0.05-0.10`)
   if the game itself has a built-in stick dead zone that the host-side
   zero-deadzone setting cannot remove (tiny movement does nothing in game).

Fixed behaviors (internal constants, not sliders): lift-off coast budget is
bounded by `0.42` full-deflection-seconds; press-to-stop engages after `0.07s`
of stillness and settles in ~0.1-0.17s; a stationary tap during coast stops
instantly.

## Next Optimization Directions

### 1. Validate the linear baseline first

Do not reintroduce speed boost as the default until the linear model is proven insufficient. The next feedback should classify the feel into:

- tiny movement does not move,
- tiny movement jumps,
- small movement is smooth but too slow,
- large movement too short,
- large movement too fast,
- direction change is delayed,
- stop behavior drifts.

### 2. Improve dead-zone compensation if tiny movement jumps

The current `Deadzone` compensation is direct: if output is non-zero but below the floor, it raises magnitude to the floor.

That may be necessary to cross the game dead zone, but it can also create a jump. If testing confirms this, replace the hard floor with a softer compensation curve:

- keep the real game-dead-zone crossing behavior,
- blend into the floor gradually,
- preserve direction,
- avoid making every tiny delta produce the same output magnitude.

Possible future parameter:

- `Micro Aim`: controls how strongly tiny output blends into dead-zone compensation.

### 3. Add instrumentation before more guessing

If the next IPA still feels wrong, add temporary diagnostics rather than only tuning:

- raw touch delta,
- residual delta,
- pending impulse,
- display-link source,
- final right-stick output,
- whether dead-zone compensation was applied,
- elapsed frame time.

This will show whether the problem is input sampling, dead-zone compensation, output smoothing, or right-stick conversion.

### 4. Keep speed boost optional

If linear aiming is good for micro aim but large swipes still feel short, first tune `Trackpad Gain`, `Peak Output`, and impulse cap.

Only after that, consider an optional `Flick Boost` parameter. It should default to `0` for shooter aiming so distance consistency remains the baseline.

### 5. Consider a separate smoothing slider only if needed

Currently `Response Time` controls most of the damping feel, and internal output smoothing uses alpha `0.68`.

If users can get distance right but cannot get smoothness right, expose a separate `Output Smoothing` parameter. Keep it hidden until testing proves `Response Time` alone is not enough.

## Current Baseline Summary

Use `RSPADALT2` with `Relative Aim` enabled to test the linear trackpad model
with lift-off coast (direction 10).

Default test values (zero-deadzone host):

- `Trackpad Gain 2.8`
- `Deadzone 0`
- `Response Time 0.075s`
- `Peak Output 0.92`

Known-good fallback:

- Set `Relative Aim` to `Turn OFF`, or choose a controller activation button and leave it unpressed, to use the traditional right-stick touchpad path. This is intentionally aligned with `RSPADALT` instead of the retired cumulative aim-offset model.

## Archived Non-Relative Aim-Offset Model

Archived on 2026-06-09.

Before the traditional fallback change, `RSPADALT2` used a separate non-relative output path when `Relative Aim` was off or inactive:

- `handleRightAimStickMove` calculated both anchor offset and per-frame fast delta.
- `sendRightAimStickOffsetEvent` mixed distance from the anchor with a speed-sensitive boost.
- `sendRightAimStickOutputEvent` applied response curve, dead-zone floor, output cap, and speed-dependent smoothing.
- Internal state included `aimFilteredTarget` / `aimHasFilteredTarget`.
- Internal constants included `aimDeadOffset`, `aimFastBoostFactor`, `aimFastBoostStart`, `aimFastBoostFull`, `aimSmoothingSlowAlpha`, and `aimSmoothingFastAlpha`.

Reason for retirement:

- The model made non-relative mode neither a plain right stick nor the relative trackpad model.
- It added speed dependence and smoothing to a fallback path that should be predictable.
- It made testing harder because `Relative Aim` activation had two different aim algorithms behind one widget.

Current replacement:

- If `Relative Aim` is active, `RSPADALT2` uses the linear display-link trackpad integrator.
- If `Relative Aim` is inactive, `RSPADALT2` uses `sendRightStickTouchPadEvent`, the same traditional right-stick path family as `RSPADALT`, with ALT circular clamp / curve and `RSPADALT2`'s output cap.
