# RSPADALT2 Aim Optimization Notes

Last updated: 2026-06-09

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

## Latest Version Direction

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

Current exposed `Relative Aim` parameters:

- `Trackpad Gain`, default `5.20`, range `1.0...10.0`
- `Deadzone`, default `0.16`, range `0.0...0.35`
- `Response Time`, default `0.060s`, range `0.030...0.140s`
- `Peak Output`, default `0.92`, range `0.20...1.00`

Current internal constants:

- `aimTrackpadNoiseDeadzone = 0.03`
- `aimTrackpadReferenceResponseTime = 0.06`
- `aimTrackpadReverseBrake = 0.12`
- `aimTrackpadMaxImpulseTime = 0.36`
- `aimTrackpadOutputSmoothingAlpha = 0.68`
- `aimTrackpadStopThreshold = 0.018`

Current data flow in `Relative Aim`:

1. `touchMoved` calculates the latest finger delta from the previous touch position.
2. Delta is multiplied by `SensitivityX/Y`.
3. Delta is added to a residual accumulator.
4. If residual magnitude is below `0.03pt`, it stays accumulated and no output is sent yet.
5. When residual passes the noise threshold, it becomes a new aim impulse:
   - `newImpulse = delta * Trackpad Gain * 0.06`
6. If new impulse direction conflicts with pending impulse direction, pending impulse is braked and previous smoothed output is cleared.
7. The impulse budget is capped by:
   - `stickInputScale * aimTrackpadMaxImpulseTime`
8. `CADisplayLink` runs every display frame while there is pending impulse.
9. Each display frame computes:
   - `source = impulse / Response Time`
10. `source` is clamped to the stick range.
11. The source is converted to right-stick coordinates.
12. `Deadzone` compensation raises very small non-zero output above the game's likely right-stick dead zone.
13. `Peak Output` caps the maximum right-stick magnitude.
14. Output smoothing is applied with alpha `0.68`, except reversed movement can bypass smoothing for immediate response.
15. The frame drains budget by:
   - `drain = source * dt`
16. When the remaining impulse drops below the stop threshold, the right stick is cleared.

## How To Tune The Latest Version

Recommended tuning order:

1. Tune `Deadzone` first.
   - If tiny finger movement still does not move the crosshair, raise it from `0.16` to `0.18-0.20`.
   - If tiny movement jumps, lower it to `0.12-0.14`.

2. Tune `Trackpad Gain` second.
   - If the whole control is too sensitive, lower it to `4.6-5.0`.
   - If large movement is too short, raise it to `5.6-6.2`.

3. Tune `Response Time` third.
   - If output feels choppy or has broken continuity, raise it to around `0.070s`.
   - If output feels laggy or drifty, lower it to `0.045-0.055s`.

4. Tune `Peak Output` last.
   - If large movement is too violent, lower it to `0.82-0.88`.
   - If large movement still cannot cover enough distance, raise it to `1.00`.

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

Use `RSPADALT2` with `Relative Aim` enabled to test the latest linear shooter-style model.

Default test values:

- `Trackpad Gain 5.20`
- `Deadzone 0.16`
- `Response Time 0.060s`
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
