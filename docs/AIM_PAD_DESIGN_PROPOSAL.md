# Aim Pad Design Proposal — Displacement-Faithful Right-Stick Aim

Last updated: 2026-06-09
Companion to: `RSPADALT2_AIM_OPTIMIZATION.md` (the iteration log). This file is the
*structural* analysis: why the current skeleton is correct, the one place it still
breaks, and a precise replacement for that one stage.

## Verdict (TL;DR)

1. **Do not rebuild from scratch, and do not start from upstream `RSVPAD`.** Upstream
   `RSVPAD` is a *weaker* version of what `RSPADALT2` already has: it maps
   `delta × VectorStickFactor` straight to the stick with no budget integrator, no
   display-link drain, and no dead-zone handling. The `RSPADALT2` v3 trackpad
   integrator (`0901448a`) is already the right architecture. Keep it.

2. **The architecture is correct; exactly one stage is wrong.** The dead-zone
   compensation (`applyTrackpadDeadzoneCompensation`) is a *hard per-sample magnitude
   floor* at 16% of full stick. That single stage causes all three remaining
   symptoms: tiny move dead/jumpy, distance inconsistent, knobs fight each other.

3. **The fix** is to replace that hard floor with an **additive dead-zone crossing
   gated by a continuous engagement envelope**, plus a **soft budget cap**. This
   decouples the four tuning knobs, which is why tuning has felt like whack-a-mole.

4. **Set expectations:** on games with a *raw* (non-rescaled) right-stick dead zone,
   there is a hard physical floor on micro-aim — the smallest visible nudge is
   `G(D) × one_frame`. No algorithm beats it. We can only cross the dead zone *once
   per stroke* (not per touch event) and make everything above it proportional.

---

## 0. PRIMARY root cause — why SLOW movement loses distance (2026-06-09 field update)

Field report: medium/fast strokes track linearly; **slow strokes — even over a long
finger distance — barely move the crosshair (pixel-by-pixel), while fast strokes
recover.** Speed-dependent *distance loss*. This is the decisive symptom; it localizes
the bug precisely and is now the headline issue (it refines §2 below).

The integrator drains the budget by the **internal `source`** value
(`drain = source · dt` in `handleAimTrackpadDisplayLink`) — which is *blind to whether
the stick output actually moved the game camera*. But the game only moves the camera by
`G(output)`, and `output` must first clear the game's right-stick dead zone and climb
the game's (convex) response curve.

For a **slow** stroke the equilibrium `source` is small (≈ `v · Gain · 0.06`), so the
output sits at/near the 16% floor — which is **inside the game's dead-zone / steep-curve
region**, where `G(output) ≈ 0`. The camera barely moves, yet the budget keeps draining
every frame regardless → the finger's displacement is *spent in the unresponsive zone*
and never becomes camera travel. A **fast** stroke pushes `source` above the floor into
the game's responsive, ~linear band, so it works.

Net: `∫ source dt` is conserved (speed-independent — which is why it *looks* linear in
the math), but **camera travel `∫ G(output) dt` is not**, because slow strokes spend
their budget where `G ≈ 0`. This is the entire "跟手" failure, and it is why no amount
of `Gain` / `Deadzone` / `Response Time` tuning fixes it — those relocate the symptom
but never reconnect *budget spent* to *camera moved*.

### The fix that addresses THIS directly: drain by real camera progress

Drain the budget by an estimate of the **actual camera rate**, not by internal `source`:

```
cameraRate ≈ G_cal(output) ≈ max(0, |output| − D_game)^γcal     // ≈ 0 inside dead zone
drain      = cameraRate · dt
```

Consequence: while output is inside the game dead zone, `drain ≈ 0` — **the budget
cannot be spent while the camera is frozen.** A slow stroke then *holds* output just
above `D_game`, drains slowly, and the camera moves slowly but *really* — total travel
∝ finger distance again, just spread over more time. Combine with:

- **Additive crossing + true `D_game`** (§3): always emit above the *real* game dead
  zone (calibratable, probably higher than the current 0.16) with a proportional term
  on top — so the held output is in the responsive band, not pinned at a dead floor.
- **Game-curve linearization** (new knob): the game response is convex; apply the
  *inverse* (concave, boosts small output, exponent < 1, default ~0.65) so equal budget
  = equal camera travel across the whole deflection range. This is the **opposite** of
  the old "Stick Curve," which crushed small output and made this worse.

Key property: the output deflection `f(budget)` now only controls **feel/lag, not
distance** (distance is governed by the matched drain). Smoothness and travel become
**independently tunable** — the decoupling every prior version lacked.

### Robust alternative (curve-agnostic): constant-rate drain / position servo

If per-game calibration of `D_game` and `γ` is too fiddly: hold a single calibrated
deflection `s*` (comfortably above the dead zone, in the linear band) whenever
`budget > 0`, and drain by the *constant* `G_cal(s*)`. Distance is then encoded purely
in **duration** (`budget / G_cal(s*)`), independent of the game's curve shape. The
crosshair moves at one consistent speed; distance is faithful. Tradeoff: big fast flicks
lag (crosshair catches up at constant speed) — mitigate with a *mild* budget-proportional
speed-up on `s*`, which does not change total distance.

### Confirm it first (one measurement, before any code change)

During a slow long drag, log `source`, `output`, `|output| − D_game`, and the running
`Σ max(0,|output|−D_game)·dt` vs `Σ |finger delta|`. Prediction: output stays ≤ the
floor / inside the dead band, and the camera-contribution sum stays ~flat while finger
distance climbs. That single trace proves the diagnosis.

---

## 1. Why the integrator is the correct skeleton (the core principle)

The streamed game's right stick is a **rate controller**: stick deflection sets the
camera *angular velocity*, and the game integrates it:

```
camera_angle(t) = ∫ G(stick(τ)) dτ          // G = game's stick→rate curve
```

"Follow-the-finger" (跟手) on a rate device means the camera *displacement* must
equal the finger *displacement*. The only way to get displacement out of a rate
controller is to feed it the **derivative** of what you want — i.e. map finger
**velocity → stick**:

```
stick = k · finger_velocity   ⟹   camera_angle = ∫ k·v dτ = k · (finger path length)
```

Two requirements fall out **for free** from this, provided the source→stick map is
linear and the budget is conserved:

- **Req: displacement is the main input.** Total camera travel ∝ total finger path. ✓
- **Req: speed-independent.** `∫ source dt = travel · Gain · const`, independent of
  *how fast* the finger moved — only the path length matters. ✓
- **Req: stop = hold, no drift.** Finger stops → v→0 → stick re-centers → camera
  holds. ✓

The current code already realizes this in *source space*. Each finger delta adds
`newImpulse = delta · Gain · 0.06` to a signed budget; the display-link drains
`source = budget / ResponseTime` per frame and removes `source · dt` from the budget.
Budget is conserved ⇒ `∫ source dt = Σ newImpulse = travel · Gain · 0.06`,
**independent of speed**. The `0.06` is just a unit constant folded into Gain;
`ResponseTime` only shapes *how the same total is spread in time* (the damping), not
the total distance. This is correct and must be preserved.

> This is also the lesson the log already reached the hard way: pure per-frame delta
> (#5) and pure velocity (#6) both failed because they are not budget-conserving;
> the v3 integrator (#8) and the linear pass (`0901448a`) are the correct direction.

---

## 2. Where it breaks: the dead zone (rigorous)

Everything above holds **only if the source→stick map is linear**. It is linear
(`touchInputToStickInput` = `stickMaxOffset · input / stickInputScale`) — *except*
for `applyTrackpadDeadzoneCompensation`, which injects a hard nonlinearity exactly
where micro-aim lives.

Concrete numbers for `RSPADALT2` (`stickInputScale = 42`, `stickMaxOffset = 0x7FFE =
32766`, `Deadzone = 0.16`):

- Floor magnitude = `32766 × 0.16 ≈ 5242` = **16% of full stick**.
- `touchInputToStickInput` maps `source ∈ [0, 42] → stick [0, 32766]` linearly.
- So **every** `source ∈ (0, 6.7]` (i.e. `0.16 × 42`) is forced up to exactly 16%.

Three failure modes, all from this one stage:

1. **Flat region kills micro-aim.** All small sources collapse to the same 16%
   output. A 2-pixel move and a 6-pixel move produce *identical* stick output ⇒ the
   crosshair cannot move *finely*; it can only move *at the 16% rate or not at all*.
   This is the "tiny movement is dead, then jumps" symptom.

2. **Per-event re-crossing = jitter.** Touch events arrive unevenly. Between two
   `touchMoved`s the budget can drain below the stop threshold, output drops under
   the floor, then the next event slams it back to 16%. Repeated 0→16%→0 pulses read
   as "jumpy/stuttery," not smooth.

3. **Knob coupling = circular tuning.** Below the floor the *effective gain is
   infinite* (any ε → 16%), so `Gain` and `Deadzone` fight: raising Deadzone to make
   tiny moves register also makes them jump; raising Gain to extend large moves also
   amplifies the floor region. This is precisely the whack-a-mole in the log.

**Inherent limit (must be communicated).** Two kinds of game dead zone:

- *Rescaled* dead zone: rate is continuous from 0 at the edge ⇒ crossing the edge is
  invisible; biasing to `D` then adding proportional signal gives perfectly smooth
  micro-aim.
- *Raw* dead zone: rate jumps to `G(D)` at the edge ⇒ the smallest possible visible
  nudge is `G(D) × one_frame`. **Unbeatable.** Our job is only to (a) cross once per
  stroke, (b) keep everything above the edge proportional, (c) expose `D` so the user
  matches the game.

---

## 3. Proposed replacement: engagement envelope + additive crossing

Replace the per-sample hard floor with two ideas:

- **Engagement envelope `E ∈ [0,1]`** — a fast-attack, late-release indicator of
  "this stroke is live," keyed on the budget. `E` crosses the dead zone **once** at
  stroke start and releases **once** at stroke end. It removes the per-event
  re-crossing entirely.
- **Additive crossing** — while engaged, output is `D_comp` *plus* a proportional
  term, so there is **always** proportional signal above the edge. No flat region.

Per display frame (replacing `applyTrackpadDeadzoneCompensation` +
`sendRightAimTrackpadSource`'s tail):

```
s      = |source|            // already clamped to stickInputScale S
û      = source / s          // direction (skip if s == 0)
sNorm  = s / S               // 0..1, linear, proportional

// envelope keyed on remaining budget: ~1 for the whole stroke, fast release at the tail
budgetNorm = |budget| / (S * engageRef)         // engageRef ~ 0.5 * maxImpulseTime
E          = smoothstep( clamp(budgetNorm / attack, 0, 1) )   // fast attack
// (E falls only when budget is nearly drained, preserving total distance)

// additive dead-zone crossing — D_comp normalized 0..1 (the game's stick dead zone)
outNorm = E * ( D_comp + (1 - D_comp) * sNorm )

out     = clamp(outNorm, 0, 1) * PeakOutput * stickMaxOffset * û
sendRightStickTouchPadEvent(out.x, out.y)
```

Behaviour, mapped to the requirements:

- **Tiny move** → small budget → `E` rises to ~1 over ~1 frame, output =
  `D_comp + tiny` for 1–2 frames, then releases. On rescaled-dead-zone games this is
  a *fine* nudge; on raw-dead-zone games it is the inherent minimum nudge. Either
  way it is **not flat** (the `(1-D_comp)·sNorm` term is live) and **not repeated**
  (one envelope per stroke). ✓ req: small move not dead / not jumpy.
- **Larger move** → bigger budget → `s` higher and `E` held longer → proportionally
  more travel, no speed boost needed. ✓ req: large move covers distance.
- **Reversal mid-stroke** → `û` flips the same frame; keep `E` engaged through the
  flip (no blank frame) so the camera reverses immediately. ✓ req: instant reverse.
- **Stop** → budget drains → `E` releases → output drops cleanly below the dead zone
  → camera stops, no creep. ✓ req: no drift.
- **Smoothness** → keep the existing light output low-pass (`α ≈ 0.68`), bypassed on
  reversal; `ResponseTime` remains the main damping knob, display-link the cadence. ✓

**Why this decouples the knobs:**

| Knob          | Now does exactly one thing                                   |
|---------------|--------------------------------------------------------------|
| `Gain`        | total camera travel per unit finger path                     |
| `D_comp`      | *only* where the dead-zone edge sits (match the game)         |
| `ResponseTime`| damping / how the same travel is spread in time              |
| `PeakOutput`  | max camera rate (safety on huge flicks)                      |

No knob bleeds into another's job, so tuning stops being circular.

---

## 4. Secondary fix: the hard budget cap reintroduces speed-dependence

`sendRightAimStickRelativeEvent` clamps the budget to
`maxImpulse = stickInputScale · aimTrackpadMaxImpulseTime = 42 × 0.36 = 15.12`.

A **fast, long** flick piles budget faster than the display-link drains it, hits the
cap, and **discards the excess** — so the same finger path travels *less* when done
fast than when done slow. That is a speed-dependent distance error at the high end
(the "large move too short / inconsistent" complaint), and it directly contradicts
the speed-invariance the rest of the design buys.

Fix: replace the hard clip with a **soft cap** — drain proportionally faster as the
budget grows (e.g. add a super-linear term to `source` when `|budget|` exceeds a
knee), so total distance is preserved while instantaneous rate stays bounded by
`PeakOutput`. Cost: a huge flick keeps the camera moving slightly after lift
("coast"). For aiming that is usually unwanted, so keep a *gentle* soft cap, not an
unbounded one — this is the one place a deliberate, *bounded* coast is acceptable.

---

## 5. Parameters (revised set)

Keep the panel small and each control honest:

- **Gain** — travel scale. (keep)
- **Dead-zone Cross** (`D_comp`) — replaces "Deadzone" but is now *additive*; set to
  the game's right-stick dead zone. (semantics changed, range `0.0…0.35`)
- **Response Time** — damping/spread. (keep)
- **Peak Output** — max rate. (keep)
- **Engage Attack / Release** — envelope ramp; hidden, sane defaults. (new, internal)
- **Flick Boost** — default **0**; optional speed boost only after the linear model
  is proven insufficient. (keep optional, per the log's stance)

---

## 6. Instrument before tuning (highest-leverage step)

The team has been tuning blind. Before another IPA, add a temporary on-screen / log
readout of: raw delta, residual, budget, source, final stick out, `E`, whether the
dead-zone term dominated, and frame dt. **Most important: log the running invariant**

```
ratio = Σ|stick_out| · dt   /   Σ|finger_delta|
```

It should be ~constant across slow vs fast strokes of equal length. If it isn't, the
budget is leaking (cap clip, stop-threshold, or the floor) and the readout shows
exactly which stage. This single check converts "it feels wrong" into a located bug.

---

## 7. Vehicle: evolve `RSPADALT2`, do not fork a new pad

Recommendation: **evolve the `RSPADALT2` Relative-Aim branch in place.** It already
owns the field plumbing (`OnScreenButtonState`), the UI panel
(`LayoutOnScreenControlsViewController.m`), the persistence/migration
(`OSCProfilesManager`, `StreamView.m`), and the integrator. A 4th right pad or a
from-scratch RSVPAD build would re-pay all of that and throw away the one part that
is already correct.

Implementation touch-list for the change above:

- `OnScreenWidgetView.swift`
  - `sendRightAimTrackpadSource` — replace `applyTrackpadDeadzoneCompensation` tail
    with the envelope + additive-crossing block (§3).
  - `handleAimTrackpadDisplayLink` — compute/advance `E`; keep drain.
  - `sendRightAimStickRelativeEvent` — swap hard cap for soft cap (§4).
  - add envelope state fields (`aimEngage`, attack/release consts).
- `CustomOSC/OnScreenButtonState.{h,m}` — `D_comp` semantics note; optional
  attack/release if exposed.
- `ViewControllers/CustomOSCViewControl/LayoutOnScreenControlsViewController.m` —
  relabel "Deadzone" → "Dead-zone Cross"; keep migration.

Keep "Relative Aim = off" (cumulative anchor) as the known-good fallback Wei already
confirmed.
