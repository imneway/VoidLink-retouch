//
//  OnScreenKey.swift
//  VoidLink
//
//  Created by True砖家 on 2024/8/4.
//  Copyright © 2024 True砖家 on Bilibili. All rights reserved.
//

import UIKit

@objc class OnScreenWidgetView: UIView, InstanceProviderDelegate, UIGestureRecognizerDelegate {
    private static let activeInstances = NSHashTable<OnScreenWidgetView>.weakObjects()
    private static var gesturesSuppressed = false

    @objc static func beginGestureSuppression() {
        if OnScreenWidgetView.gesturesSuppressed { return }
        OnScreenWidgetView.gesturesSuppressed = true
        NSLog("[InputDiag] gestureSuppression BEGIN (static=true)")
        DispatchQueue.main.async {
            for case let widget as OnScreenWidgetView in OnScreenWidgetView.activeInstances.allObjects {
                widget.cancelActiveTouchesDueToGestureSuppression()
            }
        }
    }

    @objc static func endGestureSuppression() {
        // Clear the flag synchronously. The previous implementation deferred this
        // to the next main-loop turn, which could interleave with a subsequent
        // beginGestureSuppression (that early-returns on the already-true flag) and
        // leave the process-wide static stuck `true` — suppressing ALL OSC input
        // until the app was force-quit. Synchronous clear removes that race.
        if OnScreenWidgetView.gesturesSuppressed {
            NSLog("[InputDiag] gestureSuppression END (static=false)")
        }
        OnScreenWidgetView.gesturesSuppressed = false
    }

    // Hard, unconditional reset. Called whenever the stream view is (re)configured
    // so a stuck-suppressed static self-heals without requiring a force-quit.
    @objc static func forceResetGestureSuppression() {
        if OnScreenWidgetView.gesturesSuppressed {
            NSLog("[InputDiag] gestureSuppression FORCE-RESET (was stuck true)")
        }
        OnScreenWidgetView.gesturesSuppressed = false
    }

    // Throttled (≈1/sec) diagnostic: fires when a widget touch is dropped because
    // gesture suppression is active. If this keeps logging while the user is trying
    // to play, a stuck suppression flag is eating OSC input (bug-1 signature).
    private static var lastSuppressedDropLogTime: CFTimeInterval = 0
    private static var suppressedDropCountSinceLog: Int = 0
    static func logSuppressedTouchDrop() {
        suppressedDropCountSinceLog += 1
        let now = CACurrentMediaTime()
        if now - lastSuppressedDropLogTime >= 1.0 {
            NSLog("[InputDiag] OSC touch dropped by gestureSuppression x%d in last %.1fs (suppression stuck?)",
                  suppressedDropCountSinceLog, now - lastSuppressedDropLogTime)
            lastSuppressedDropLogTime = now
            suppressedDropCountSinceLog = 0
        }
    }

    // MARK: - Apple Pencil passthrough
    // Pencil input must ignore every OSC widget and reach the stream instead
    // (finger-only OSC, like the system-wide "draw with Apple Pencil only" idea).
    // StreamView registers itself here during setup; at runtime each widget
    // forwards pencil touches to it untouched instead of handling them itself.
    // Edit mode is exempt so widgets can still be selected/dragged with a pencil.
    @objc static weak var pencilPassthroughTarget: UIView?
    private var passthroughPencilTouches = Set<UITouch>()

    // Splits pencil touches out of `touches`, forwards them to the passthrough
    // target for the given phase, and returns the remaining (finger) touches the
    // widget should keep handling. The began-time decision sticks for the touch's
    // whole lifetime, even if edit mode flips mid-gesture.
    private func extractPencilPassthroughTouches(_ touches: Set<UITouch>, with event: UIEvent?, phase: UITouch.Phase) -> Set<UITouch> {
        let forwarded: Set<UITouch>
        if phase == .began {
            guard !OnScreenWidgetView.editMode, OnScreenWidgetView.pencilPassthroughTarget != nil else { return touches }
            forwarded = touches.filter { $0.type == .pencil }
            passthroughPencilTouches.formUnion(forwarded)
        } else {
            guard !passthroughPencilTouches.isEmpty else { return touches }
            forwarded = touches.filter { passthroughPencilTouches.contains($0) }
            if phase == .ended || phase == .cancelled {
                passthroughPencilTouches.subtract(forwarded)
            }
        }
        guard !forwarded.isEmpty else { return touches }
        // If the target got torn down mid-touch, still keep the tracked pencil
        // touches away from the widget logic — it never owned them.
        if let target = OnScreenWidgetView.pencilPassthroughTarget {
            switch phase {
            case .began: target.touchesBegan(forwarded, with: event)
            case .moved: target.touchesMoved(forwarded, with: event)
            case .ended: target.touchesEnded(forwarded, with: event)
            case .cancelled: target.touchesCancelled(forwarded, with: event)
            default: break
            }
        }
        return touches.subtracting(forwarded)
    }

    // receiving the OnScreenControls instance from delegate
    @objc func getOnScreenControlsInstance(_ sender: Any) {
        if let controls = sender as? OnScreenControls {
            self.onScreenControls = controls
            // Tell ControllerSupport which kind of gyro gate this widget needs.
            // Without this the gyro tick stays in legacy always-on mode. A conditional
            // widget carries gyro in its base and/or armed branch (not motionControlButtonString),
            // so register for every motion token this widget can emit.
            for motion in [self.motionControlButtonString, self.conditionBaseMotionString, self.conditionArmedMotionString] {
                switch motion {
                case "GYRO":      controls.markGyroToggleButtonRegistered()
                case "GYROPAUSE": controls.markGyroPauseButtonRegistered()
                default: break
                }
            }
            print("ClassA received OnScreenControls instance: \(controls)")
        } else {
            print("ClassA received an unknown sender")
        }
    }
    
    @objc public weak var guidelineDelegate: OnScreenWidgetGuidelineUpdateDelegate?
    
    @objc protocol OnScreenWidgetGuidelineUpdateDelegate: AnyObject {
        func updateGuidelinesForOnScreenWidget(_ sender: Any)
    }
    
    @objc enum WidgetTypeEnum: UInt8 {
        case uninitialized
        case button
        case touchPad
        case fullscreenTrigger
    }

    @objc public static let FULLSCREEN_SHAPE = "fullscreen"
    
    @objc public var widgetType: WidgetTypeEnum = WidgetTypeEnum.uninitialized
    @objc static public var obscuredByAlpha: Bool = false
    
    @objc static public var editMode: Bool = false
    @objc public var buttonLabel: String
    @objc public var cmdString: String
    private var buttonString: String = ""
    private var touchPadString: String = ""
    // Motion-control command extracted from cmdString combos (e.g. "OSCR2+GYRO").
    // Empty when the widget has no motion behavior. See CommandManager.motionControlButtonCmds.
    private var motionControlButtonString: String = ""
    // super combo key string set
    private var comboButtonStrings: [String] = []
    private var comboKeyTimeIntervalMs: UInt32 = 0
    // Per-token "tap" flags parallel to comboButtonStrings: true = press then auto-release
    // mid-sequence (don't hold to widget release). Empty array = all-hold (legacy behavior).
    private var comboButtonTapFlags: [Bool] = []

    // Conditional widget (cmdString "COND:base:arm:armedOutput", see CommandManager).
    // When armed (arm tokens ⊆ last activation), the press fires armedOutput instead of
    // the base combo (comboButtonStrings). base IS the "not armed" branch, so the normal
    // comboButtonStrings/comboButtonTapFlags/comboKeyTimeIntervalMs hold the base output.
    private var isConditional: Bool = false
    private var conditionArmTokens: [String] = []
    private var conditionArmedStrings: [String] = []
    private var conditionArmedTapFlags: [Bool] = []
    private var conditionArmedIntervalMs: UInt32 = 0
    // Per-branch gyro/motion (GYRO/GYROPAUSE pulled out of each output combo). Gyro is a
    // hold-tied mode, not a press, so it lives outside comboButtonStrings and activates for
    // whichever branch actually fired — armed-only gyro stays off during the base output.
    private var conditionBaseMotionString: String = ""
    private var conditionArmedMotionString: String = ""
    // Branch latched at button-down so button-up releases exactly what went down,
    // even if the arming state changed while the button was held.
    private var heldDispatchStrings: [String]? = nil
    private var heldDispatchIntervalMs: UInt32 = 0
    // Motion string actually activated at button-down, so button-up deactivates the same one.
    private var heldMotionString: String = ""

    @objc public var pressed: Bool
    private var restoreAlphaAfterRelease: Bool = false
    @objc public var widthFactor: CGFloat = 1.0
    @objc public var heightFactor: CGFloat = 1.0
    @objc public var slideMode: Int = 0

    @objc public var deNormalizedWidthFactor: CGFloat = 1.0
    @objc public var deNormalizedHeightFactor: CGFloat = 1.0
    
    @objc public var borderWidth: CGFloat = 0.0
    @objc public var backgroundAlpha: CGFloat = 0.5
    @objc public var textAlpha: CGFloat = 0.64
    @objc public var vibrationStyle: Int = 6
    @objc public var latestTouchLocation: CGPoint
    @objc public var selfViewOnTheRight: Bool = false
    @objc public var shape: String = "default"
    @objc public var storedCenter: CGPoint = .zero // location from persisted data
    @objc public var initialCenter: CGPoint = .zero // location from persisted data
    @objc public var layoutChanges: [CGPoint] = []
    @objc public var mouseButtonAction: MouseButtonAction = .hovering;
    
    private let appWindow: UIView
    
    private var vibrationGenerator = UIImpactFeedbackGenerator(style: .light)
    private var vibrationOn: Bool = false

    // for all touchPad or buttons hybrid with touchPads
    @objc public var hasStickIndicator: Bool = false
    @objc public var hasSensitivityTweak: Bool = false
    @objc public var hasResponseCurveTweak: Bool = false
    @objc public var hasAimTweak: Bool = false
    @objc public var hasDoubleTapStickClickTweak: Bool = false
    @objc public var doubleTapStickClickEnabled: Bool = true
    
    // for all stick pads
    @objc public var minStickOffset: CGFloat = 0
    public let stickMaxOffset: CGFloat = 0x7FFE

    // Response curve exponent applied to ALT stick pads after the circular clamp.
    // 1.0 = linear (legacy). >1 compresses small finger displacements into smaller
    // outputs while keeping full deflection at the same boundary, so a slow tweak
    // gives precision and a fast swing still reaches max — useful for hybrid
    // camera + aim use cases (e.g. bow scopes). Pair with stickInputScale to
    // control physical range vs softness independently. 1.0 linear · 1.3 default
    // (mild precision) · 1.5–1.8 stronger precision at the cost of mid-range slope.
    @objc public var stickResponseExponent: CGFloat = 1.38

    @objc public var aimMaxOutputScale: CGFloat = 0.92 {
        didSet {
            if !aimMaxOutputScale.isFinite {
                aimMaxOutputScale = oldValue
            }
            aimMaxOutputScale = min(max(aimMaxOutputScale, 0.20), 1.0)
        }
    }
    @objc public var aimTrackpadGain: CGFloat = 2.8 {
        didSet {
            if !aimTrackpadGain.isFinite {
                aimTrackpadGain = oldValue
            }
            aimTrackpadGain = min(max(aimTrackpadGain, 0.5), 10.0)
        }
    }
    @objc public var aimTrackpadDeadzoneCompensation: CGFloat = 0 {
        didSet {
            if !aimTrackpadDeadzoneCompensation.isFinite {
                aimTrackpadDeadzoneCompensation = oldValue
            }
            aimTrackpadDeadzoneCompensation = min(max(aimTrackpadDeadzoneCompensation, 0.0), 0.35)
        }
    }
    @objc public var aimTrackpadResponseDuration: CGFloat = 0.075 {
        didSet {
            if !aimTrackpadResponseDuration.isFinite {
                aimTrackpadResponseDuration = oldValue
            }
            aimTrackpadResponseDuration = min(max(aimTrackpadResponseDuration, 0.03), 0.14)
        }
    }
    // Axis-snap cone half-angle in degrees for relative aim. Strokes within
    // this angle of an axis get the cross-axis component compressed so thumb
    // arcs read as straight lines. 0 disables.
    @objc public var aimTrackpadAxisSnapDegrees: CGFloat = 10 {
        didSet {
            if !aimTrackpadAxisSnapDegrees.isFinite {
                aimTrackpadAxisSnapDegrees = oldValue
            }
            aimTrackpadAxisSnapDegrees = min(max(aimTrackpadAxisSnapDegrees, 0.0), 20.0)
        }
    }
    @objc public var aimRelativeModeEnabled: Bool = false
    @objc public var aimRelativeActivationButton: String = CommandManager.aimRelativeActivationOff {
        didSet {
            let normalized = CommandManager.normalizedAimRelativeActivationCommand(aimRelativeActivationButton)
            if aimRelativeActivationButton != normalized {
                aimRelativeActivationButton = normalized
                return
            }
            aimRelativeModeEnabled = normalized != CommandManager.aimRelativeActivationOff
        }
    }

    
    // for LSVPAD, RSVPAD
    @objc public var deltaX: CGFloat
    @objc public var deltaY: CGFloat

    // for LSPAD, RSPAD
    @objc public var offSetX: CGFloat
    @objc public var offSetY: CGFloat
    private let crossMarkColor: CGColor = UIColor(white: 1, alpha: 0.70).cgColor
    private let stickBallColor: CGColor = UIColor(white: 1, alpha: 0.75).cgColor
    // Finger displacement (in points) at which the stick reaches full deflection.
    // Smaller = more sensitive (less travel). Wider = more precision band.
    // Default 35 keeps legacy non-ALT pads unchanged; ALT pads override to ~80
    // at init so the response curve has room to be both soft and smooth.
    @objc public var stickInputScale: CGFloat = 35 {
        didSet {
            if !stickInputScale.isFinite || stickInputScale <= 0 {
                stickInputScale = oldValue
            }
        }
    }

    // Per-axis output flip for stick pads. Useful when a game's camera axis
    // convention is reversed (e.g. inverted-Y aim, bow scope where tilting
    // up should pan down). Applied at the source axis so deadband / curve /
    // clamp all see the post-flip sign — see sendRightStickTouchPadEvent.
    // UI exposes these only for ALT pads (gated by hasResponseCurveTweak),
    // but the logic is type-agnostic at runtime.
    @objc public var stickInvertVertical: Bool = false
    @objc public var stickInvertHorizontal: Bool = false
    private var l3r3Indicator = CAShapeLayer()
    private let stickBallMaxOffset = 18.0
    @objc public var crossMarkLayer = CAShapeLayer()
    @objc public var stickBallLayer = CAShapeLayer()
    // ALT stick indicator (Genshin-like)
    private var altPointerLayer = CALayer()
    private var altBackgroundLayer = CALayer()
    @objc public var altIndicatorSize: CGFloat = 160
    private let altIndicatorMaxScale: CGFloat = 1.05
    private var touchBeganPosInSuperLayer: CGPoint = .zero

    // this is for all stick pads and mouse Pad
    @objc public var sensitivityFactorX: CGFloat = 1.0
    @objc public var sensitivityFactorY: CGFloat = 1.0
    @objc public var aimSensitivityFactorX: CGFloat = 1.0
    @objc public var aimSensitivityFactorY: CGFloat = 1.0

    // check quick double tap:
    private var quickDoubleTapDetected: Bool
    private var quickDoubleTapComboHeld: Bool = false
    private var touchTapTimeInterval: TimeInterval
    private var touchTapTimeStamp: TimeInterval
    private let QUICK_TAP_TIME_INTERVAL = 0.2
    private let ALT_STICK_DOUBLE_TAP_STATIONARY_SLOP: CGFloat = 8.0
    // ALT stick pads defer the double-tap stick-click by this long: the second
    // tap's DOWN alone can't distinguish a stick-click from a quick re-grip that
    // immediately drags. Movement beyond the tap slop inside the window cancels
    // the click; a lift inside the window fires a clean press+release; a touch
    // still stationary at the deadline fires with hold semantics.
    private static let altDoubleTapConfirmDelay: TimeInterval = 0.08
    private var pendingDoubleTapComboWork: DispatchWorkItem? = nil
    private var altStickTouchMovedBeyondTapSlop: Bool = false

    // Stick/direction pads are single-logical-touch surfaces, but the view must
    // still enable multi-touch (see touchesBegan): with it off, UIKit silently
    // drops a new touch that overlaps the previous one (fast re-grips: the new
    // contact lands before the old one fully lifts) and NEVER delivers it — the
    // pad reads dead for that entire grip. Instead we designate one primary touch,
    // ignore extras, and adopt a live successor when the primary lifts.
    private var primaryPadTouchId: ObjectIdentifier? = nil
    private var usesPrimaryTouchTracking: Bool {
        return widgetType == WidgetTypeEnum.touchPad
            && !touchPadString.isEmpty
            && touchPadString != "MOUSEPAD"
            && touchPadString != "DS4TOUCH"
    }

    private func adoptSuccessorPadTouch(from event: UIEvent?, excluding ended: Set<UITouch>) {
        guard let successor = event?.allTouches?.first(where: { candidate in
            candidate.view == self
                && !ended.contains(candidate)
                && !passthroughPencilTouches.contains(candidate)
                && (candidate.phase == .began || candidate.phase == .moved || candidate.phase == .stationary)
        }) else { return }
        primaryPadTouchId = ObjectIdentifier(successor)
        // Fresh anchor at the successor's current position — the new grip's stroke
        // starts from zero deflection there.
        touchBegan = true
        firstTouchMoved = false
        touchBeganLocation = successor.location(in: self)
        latestTouchLocation = touchBeganLocation
        if let superLayer = self.layer.superlayer {
            touchBeganPosInSuperLayer = superLayer.convert(touchBeganLocation, from: self.layer)
        }
        if isAimStickPad { aimHasAnchor = false }
        // Direction pads: the primary's lift released every direction host-side.
        // Without resetting the mask state, a successor moving in the SAME
        // direction reproduces the old mask and sends no new DOWN.
        previousButtonMask = Direction.initialStatus.rawValue
        directionPadTouchBegan = true
    }
    private var altStickTouchHadMultipleTouches: Bool = false
    private var lastAltStickTouchWasStationaryTap: Bool = true
    @objc public var stickIndicatorOffset: CGFloat = 120
    
    // for all LRUD pads
    private var upIndicator = CAShapeLayer()
    private var downIndicator = CAShapeLayer()
    private var leftIndicator = CAShapeLayer()
    private var rightIndicator = CAShapeLayer()
    
    // for DPAD LRUD pad
    private var lrudIndicatorBall = CAShapeLayer()
    private let triggeringAngle = 67.5
    private enum Direction: Int {
        case right = 1
        case up = 2
        case left = 4
        case down = 8
        case initialStatus = 16
    }
    private var previousButtonMask = Direction.initialStatus.rawValue
    // Forces the first mask evaluation after touchesBegan to fire even when the
    // computed mask equals the stale previousButtonMask (upstream 297f5ad7).
    private var directionPadTouchBegan = false
    
    // OnScreenControls instance
    private var onScreenControls: OnScreenControls
    
    // 存储原始透明度值
    private var originalOpacityValues: [String: Float] = [:]
    
    // key / button label
    private let label: UILabel
    private let outlineLabel: UILabel
    private let defaultLabelTextAlpha: CGFloat = 0.64
    private let defaultLabelStrokeAlpha: CGFloat = 0.20
    
    // first touch location within the button or pad view (self)
    @objc public var touchBeganLocation: CGPoint = .zero
    
    // for mousePad
    private var touchLockedForMoveEvent: UITouch
    private var touchBegan: Bool = false
    private var firstTouchMoved: Bool = false
    private var mousePointerMoved: Bool
    private var twoTouchesDetected: Bool

    private var aimLastMoveTimestamp: CFTimeInterval = 0
    private var aimAnchorLocation: CGPoint = .zero
    private var aimHasAnchor = false
    private var aimTrackpadDisplayLink: CADisplayLink?
    private var aimTrackpadImpulse: CGPoint = .zero
    private var aimTrackpadResidualDelta: CGPoint = .zero
    // Touch deltas land here on the touch-event clock; the display link consumes
    // the whole batch once per frame. Injecting on the frame clock instead of the
    // touch clock removes the sawtooth/beat ripple the two unsynchronized clocks
    // produce in the stick output.
    private var aimTrackpadPendingDelta: CGPoint = .zero
    private var aimTrackpadLastFrameTimestamp: CFTimeInterval = 0
    private var aimTrackpadLastOutput: CGPoint = .zero
    private var aimTrackpadHasOutput = false
    private var aimTrackpadLastInjectTimestamp: CFTimeInterval = 0
    private var aimTouchSawMovement = false
    private var aimTouchBeganWhileCoasting = false
    private var aimRelativeModeWasActive = false
    private let aimTrackpadNoiseDeadzone: CGFloat = 0.03
    private let aimTrackpadReferenceResponseTime: CGFloat = 0.06
    // Only a genuine reversal (angle > ~104°) clears the pending impulse.
    // Oblique course changes merge via vector addition; braking them too made
    // slow precision aim stutter because touch direction noise kept tripping it.
    private let aimTrackpadReverseAlignment: CGFloat = -0.25
    private let aimTrackpadMaxImpulseTime: CGFloat = 0.42
    // Output smoothing as time constants so the filter strength is frame-rate
    // independent: alpha = 1 - exp(-dt/tau). The reverse tau stays short to keep
    // direction flips responsive without the old one-frame snap.
    private let aimTrackpadOutputSmoothingTau: CGFloat = 0.020
    private let aimTrackpadOutputReverseTau: CGFloat = 0.008
    private let aimTrackpadStopThreshold: CGFloat = 0.003
    // Finger resting on screen with no effective injection for this long means
    // "hold still" — the impulse pool then decays fast (press-to-stop). Lift-off
    // skips this decay so a fast swipe's stored budget coasts to completion.
    private let aimTrackpadStillHoldDelay: CFTimeInterval = 0.07
    private let aimTrackpadStillDecayTau: CGFloat = 0.05
    
    // trackball
    private var trackballVelocity: CGPoint = .zero
    private var trackballDecelerationTimer: Timer?
    @objc public var trackballDecelerationRate: CGFloat = 0.93
    private let trackballVelocityThreshold: CGFloat = 0.1
    
    
    // border & visual effect
    private var minimumBorderAlpha: CGFloat = 0.19
    private var defaultBorderColor: CGColor = UIColor(white: 0.2, alpha: 0.3).cgColor
    private let highlightAlphaRange: (min: CGFloat, max: CGFloat) = (0.002, 0.4)
    private let highlightReferenceBackgroundAlpha: CGFloat = 0.5
    
    //slide buttons
    private var capturedTouches: NSMutableSet
    private let noTouch: UITouch = UITouch()

    // Serial queue for combo press/release sequences. These used to run on the
    // CONCURRENT global queue: with per-token delays (usleep) still in flight, a
    // quick tap's UP block could overtake the delayed DOWN block and the host was
    // left with the key stuck pressed. One serial queue per widget keeps every
    // down/up sequence in submission order while staying off the main thread.
    // Per-widget FIFO that TARGETS the app-wide serial key queue: this widget's
    // sequences stay ordered AND can't interleave with any other widget's (or a
    // legacy "+" combo's) raw DOWN/UP events mid-chord.
    private let comboSendQueue = DispatchQueue(label: "com.voidlink.combo-send", qos: .userInteractive, target: CommandManager.keySendSerialQueue)
    
    //controller touch pad
    private var pointerIdPool: Set<UInt32>
    private var pointerIdDict: Dictionary<ObjectIdentifier, UInt32>
    private var activePointerIds: Set<UInt32>
    
    // whole button press down visual effect
    @objc public let buttonDownVisualEffectLayer = CAShapeLayer()
    private var buttonDownVisualEffectWidth: CGFloat

    private var isAltStickPad: Bool {
        return self.touchPadString == "LSPADALT"
            || self.touchPadString == "RSPADALT"
            || self.touchPadString == "RSPADALT2"
    }

    private var isRightAltStickPad: Bool {
        return self.touchPadString == "RSPADALT"
            || self.touchPadString == "RSPADALT2"
    }

    private var isAimStickPad: Bool {
        return self.touchPadString == "RSPADALT2"
    }

    private var shouldShowRuntimeStickIndicator: Bool {
        if self.isAimStickPad {
            return !self.isAimRelativeModeActive
        }
        return true
    }

    private func highlightAlpha(for backgroundAlpha: CGFloat) -> CGFloat {
        let clampedBackground = max(0.0, min(backgroundAlpha, highlightReferenceBackgroundAlpha))
        guard highlightReferenceBackgroundAlpha > 0 else { return highlightAlphaRange.max }
        let normalized = clampedBackground / highlightReferenceBackgroundAlpha
        return highlightAlphaRange.min + normalized * (highlightAlphaRange.max - highlightAlphaRange.min)
    }

    private var buttonHighlightAlpha: CGFloat {
        return highlightAlpha(for: backgroundAlpha)
    }

    private var buttonHighlightColor: UIColor {
        return UIColor(white: 1.0, alpha: buttonHighlightAlpha)
    }

    private var buttonHighlightCGColor: CGColor {
        return buttonHighlightColor.cgColor
    }

    
    @objc init(cmdString: String, buttonLabel: String, shape:String) {
        
        self.cmdString = cmdString
        self.touchPadString = ""

        if let condComps = CommandManager.shared.conditionalCommandComponents(cmdString),
           CommandManager.shared.isConditionalCommand(cmdString) {
            // Conditional widget: "COND:base:arm:armedOutput". The base drives the normal
            // button behavior (and is the "not armed" output); arm/armedOutput are parsed
            // separately and consulted at press time (see resolveDispatch / handleButtonDown).
            self.isConditional = true
            self.widgetType = WidgetTypeEnum.button
            let base = OnScreenWidgetView.parseButtonOutput(condComps[0])
            self.comboButtonStrings = base.tokens
            self.comboButtonTapFlags = base.taps
            self.comboKeyTimeIntervalMs = base.intervalMs
            self.conditionBaseMotionString = base.motion
            self.buttonString = base.tokens.first ?? ""
            self.conditionArmTokens = OnScreenWidgetView.parseButtonOutput(condComps[1]).tokens
            let armed = OnScreenWidgetView.parseButtonOutput(condComps[2])
            self.conditionArmedStrings = armed.tokens
            self.conditionArmedTapFlags = armed.taps
            self.conditionArmedIntervalMs = armed.intervalMs
            self.conditionArmedMotionString = armed.motion
        }
        else if !self.cmdString.contains("+"){
            // 安全解包并处理 `comboKeyStrings`
            // Validate against the known-token grammar on a tap-marker-stripped copy ('*' is a
            // per-token tap flag the grammar doesn't recognize), then tokenize WITH tap flags so
            // a plain combo widget can also use "OSCB*-OSCR2" — not just conditional outputs.
            let tapStripped = OnScreenWidgetView.stripTrailingTapMarkers(self.cmdString)
            if CommandManager.shared.extractSinglCmdStringsFromComboKeys(from: tapStripped) != nil {

                let parsed = OnScreenWidgetView.parseComboString(self.cmdString)  // tokens (* stripped), tap flags, interval
                self.comboKeyTimeIntervalMs = parsed.intervalMs
                let comboStrings = parsed.tokens

                if CommandManager.touchPadCmds.contains(comboStrings.first ?? "") {self.widgetType = WidgetTypeEnum.touchPad}
                else {self.widgetType = WidgetTypeEnum.button}

                let touchPadString = Set(comboStrings).intersection(Set(CommandManager.touchPadCmds)).first ?? ""
                let motionString = Set(comboStrings).intersection(Set(CommandManager.motionControlButtonCmds)).first ?? ""
                // Drop the touchpad/motion tokens but keep each remaining button's tap flag aligned.
                var buttonTokens: [String] = []
                var buttonTaps: [Bool] = []
                for (index, token) in comboStrings.enumerated() {
                    if token != touchPadString && token != motionString {
                        buttonTokens.append(token)
                        buttonTaps.append(index < parsed.taps.count ? parsed.taps[index] : false)
                    }
                }
                self.comboButtonStrings = buttonTokens
                self.comboButtonTapFlags = buttonTaps
                self.touchPadString = touchPadString
                self.motionControlButtonString = motionString
                self.buttonString = self.comboButtonStrings.first ?? ""
                
               //  let stickAndMouseTouchpads = ["LSPAD", "RSPAD", "LSVPAD", "RSVPAD", "MOUSEPAD"]
                let nonVectorStickPads = CommandManager.nonVectorStickPads
               // if CommandManager.touchPadCmds.contains(self.touchPadString) {self.hasSensitivityTweak = true}
                self.hasSensitivityTweak = CommandManager.touchPadCmds.contains(self.touchPadString)
                
                // if nonVectorStickPads.contains(self.touchPadString) && widgetType == WidgetTypeEnum.touchPad {self.hasStickIndicator = true}
                self.hasStickIndicator = nonVectorStickPads.contains(self.touchPadString) && widgetType == WidgetTypeEnum.touchPad
                
                switch self.cmdString {
                case "LSPAD", "LSPADALT", "LSVPAD":
                    self.comboButtonStrings = ["OSCL3"]
                case "RSPAD", "RSPADALT", "RSPADALT2", "RSVPAD":
                    self.comboButtonStrings = ["OSCR3"]
                case "DS4TOUCH":
                    self.comboButtonStrings = ["DS4TCHBTN"]
                default: break
                }

                // ALT pads: widen the playable range so the response curve can
                // be both soft at low end and smooth approaching max. Without
                // this the 35pt boundary forces any precision-shaped curve to
                // become very steep near full deflection (1mm = 20% jumps).
                // 55 puts max deflection at ~12mm finger travel (vs 7mm @35
                // and 17mm @80) — enough room for a mild curve, not so wide
                // that reaching max becomes its own chore.
                if self.touchPadString == "RSPADALT" || self.touchPadString == "LSPADALT" || self.touchPadString == "RSPADALT2" {
                    self.stickInputScale = 55
                    self.hasResponseCurveTweak = true
                }
                if self.touchPadString == "RSPADALT2" {
                    self.stickInputScale = 42
                    self.stickResponseExponent = 1.18
                    self.minStickOffset = self.stickMaxOffset * 0.06
                    self.aimMaxOutputScale = 0.92
                    self.aimTrackpadGain = 2.8
                    self.aimTrackpadDeadzoneCompensation = 0
                    self.aimTrackpadResponseDuration = 0.075
                    self.aimTrackpadAxisSnapDegrees = 10
                    self.hasAimTweak = true
                }
                if self.touchPadString == "LSPADALT" || self.touchPadString == "RSPADALT" || self.touchPadString == "RSPADALT2" {
                    self.hasDoubleTapStickClickTweak = true
                }
            }
            else {print("无法从 keyString 提取 comboKeyStrings")}
        }
        else {
            self.widgetType = WidgetTypeEnum.button // legacy combo button connected by "+"
        }
        
        
        print("widgetType: \(self.widgetType)")
        print("touchPadString: \(self.touchPadString)")
        for comboButtonString in comboButtonStrings {
            print("comboButtonString: \(comboButtonString)")
        }

        self.buttonLabel = buttonLabel
        self.shape = shape
        // Full-screen trigger widget: shape override forces widgetType regardless of cmdString,
        // so bound cmd still resolves via existing button / combo mappings but behavior switches
        // to double-tap-to-fire, full-screen invisible overlay.
        if shape == OnScreenWidgetView.FULLSCREEN_SHAPE {
            self.widgetType = WidgetTypeEnum.fullscreenTrigger
            // For "+"-style legacy keyboard combos (e.g. "A+B") leave comboButtonStrings empty so
            // handleFullscreenDoubleTap falls into the extractKeyStringsFromComboCommand branch.
            // The single-token send path (sendComboButtonsDownEvent) only handles already-split
            // tokens that match the keyboard / mouse / osc / touchpad mapping tables.
            if self.comboButtonStrings.isEmpty && !self.cmdString.contains("+") {
                self.comboButtonStrings = [self.cmdString]
            }
            self.buttonString = self.comboButtonStrings.first ?? self.cmdString
            self.touchPadString = ""
            self.hasStickIndicator = false
            self.hasSensitivityTweak = false
        }
        self.label = UILabel()
        self.outlineLabel = UILabel()
        // self.originalBackgroundColor = UIColor(white: 0.2, alpha: 0.7)
        self.pressed = false
        // self.widthFactor = 1.0
        // self.heightFactor = 1.0
        // self.backgroundAlpha = 0.5
        // self.velocityFactor = 1.0

        self.latestTouchLocation = CGPoint(x: 0, y: 0)
        self.deltaX = 0
        self.deltaY = 0
        self.offSetX = 0
        self.offSetY = 0
        self.onScreenControls = OnScreenControls()
        self.appWindow = UIApplication.shared.windows.first!
        self.quickDoubleTapDetected = false
        self.touchTapTimeInterval = 100
        self.touchTapTimeStamp = 100
        self.buttonDownVisualEffectWidth = 0
        self.mousePointerMoved = false
        self.touchLockedForMoveEvent = UITouch()
        self.twoTouchesDetected = false
        self.stickIndicatorOffset = 95
        self.sensitivityFactorX = 1.0
        self.sensitivityFactorY = 1.0
        self.aimSensitivityFactorX = 1.0
        self.aimSensitivityFactorY = 1.0
        self.capturedTouches = NSMutableSet()
        self.pointerIdDict = [:]
        self.pointerIdPool = []
        for i in 0...10 { // iPadOS supports up to 11 finger touches
            self.pointerIdPool.insert(UInt32(i))
        }
        self.activePointerIds = []
        super.init(frame: .zero)
        OnScreenWidgetView.activeInstances.add(self)
        if self.isAltStickPad { self.stickIndicatorOffset = 0; self.hasStickIndicator = false }
        
        upIndicator = createLrudDirectionLayer()
        upIndicator.anchorPoint = CGPoint(x: 0.5, y: 1)
        downIndicator = createLrudDirectionLayer()
        downIndicator.anchorPoint = CGPoint(x: 0.5, y: 0)
        leftIndicator = createLrudDirectionLayer()
        leftIndicator.anchorPoint = CGPoint(x: 1, y: 0.5)
        rightIndicator = createLrudDirectionLayer()
        rightIndicator.anchorPoint = CGPoint(x: 0, y: 0.5)
    
        setupView()
        
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        aimTrackpadDisplayLink?.invalidate()
        OnScreenWidgetView.activeInstances.remove(self)
    }
    
    // ======================================================================================================
    
    @objc public func setVibration(style: Int) {
        if #available(iOS 13.0, *) {
            vibrationOn = style < UIImpactFeedbackGenerator.FeedbackStyle.rigid.rawValue + 1
        } else {
            vibrationOn = style < UIImpactFeedbackGenerator.FeedbackStyle.heavy.rawValue + 1
        };
        vibrationStyle = style;
        if #available(iOS 13.0, *) {
            print("rigid value \(UIImpactFeedbackGenerator.FeedbackStyle.rigid.rawValue)")
        } else {
            // Fallback on earlier versions
        };
        if vibrationOn {
            vibrationGenerator = UIImpactFeedbackGenerator(style: UIImpactFeedbackGenerator.FeedbackStyle(rawValue: style) ?? UIImpactFeedbackGenerator.FeedbackStyle.light)
        }
    }
    
    @objc public func setLocation(position: CGPoint) {
        /*
        NSLayoutConstraint.activate([
            self.centerXAnchor.constraint(equalTo: self.superview!.leadingAnchor, constant: xOffset),
            self.centerYAnchor.constraint(equalTo: self.superview!.topAnchor, constant: yOffset),
        ])
         */
        storedCenter = position
        center = storedCenter
        initialCenter = storedCenter;
        layoutChanges.append(initialCenter)
    }
    
    @objc public func enableRelocationMode(enabled: Bool){
        OnScreenWidgetView.editMode = enabled
    }
    
    @objc public func undoRelocation(){
        guard layoutChanges.count>1 else {return}
        UIView.animate(withDuration: 0.2) {
            self.center = self.layoutChanges[self.layoutChanges.count-2]
        }
        storedCenter = center
        layoutChanges.removeLast()
    }

    @objc public func adjustTransparency(alpha: CGFloat){
        if widgetType == WidgetTypeEnum.fullscreenTrigger {
            // Fullscreen trigger owns its own background through setupFullscreenTriggerView
            // (clear at runtime, faint dark tint in editor). tweakAlpha would paint a gray
            // bg across the entire screen, which is then only reset by the follow-up
            // setupView call inside adjustBorder — fragile. Just no-op here.
            return
        }
        if alpha != 0 {
            self.backgroundAlpha = alpha
        }
        else{
            // self.backgroundAlpha = 0.5
            self.backgroundAlpha = alpha
        }
        self.tweakAlpha()
    }

    @objc public func adjustTextAlpha(alpha: CGFloat) {
        if widgetType == WidgetTypeEnum.fullscreenTrigger { return }
        self.textAlpha = max(0.0, min(alpha, 1.0))
        self.applyLabelTextAppearance()
    }
    
    @objc public func adjustBorder(width: CGFloat){
        self.borderWidth = width
        // self.layer.borderWidth = borderWidth
        // if CommandManager.touchPadCmds.contains(self.keyString) && width == 0 {self.layer.borderWidth = 1}
        setupView()
    }
    
    // 降低指定控件的透明度
    private func dimControlsForAltPad() {
        guard let superview = self.superview else { return }
        
        // 根据不同的 Alt Pad 类型确定需要降低透明度的控件
        let controlNames: [String]
        let widgetControlNames: [String] // OnScreenWidgetView 创建的控件代号
        
        if self.touchPadString == "LSPADALT" {
            controlNames = ["upButton", "downButton", "leftButton", "rightButton", "selectButton", "l3Button", "leftStick"]
            widgetControlNames = ["L3", "LS", "OSCL3"] // 用户通过布局编辑界面创建的控件代号
        } else if self.isRightAltStickPad {
            controlNames = ["aButton", "bButton", "xButton", "yButton", "startButton", "r3Button", "l3Button"]
            widgetControlNames = ["A", "B", "X", "Y", "Start", "R3", "RS", "OSCR3"] // 用户通过布局编辑界面创建的控件代号
        } else {
            return
        }
        
        // 首先处理 OnScreenWidgetView 创建的控件（包括用户自定义的 L3、LS、R3、RS 等）
        for subview in superview.subviews {
            if let widgetView = subview as? OnScreenWidgetView {
                // 检查是否是目标控件
                let shouldDim = controlNames.contains(where: { controlName in
                    widgetView.buttonString == controlName || 
                    widgetView.touchPadString == controlName ||
                    widgetView.cmdString == controlName
                }) || widgetControlNames.contains(where: { widgetName in
                    widgetView.cmdString == widgetName ||
                    widgetView.buttonString == widgetName ||
                    widgetView.touchPadString == widgetName
                })
                
                if shouldDim {
                    // 存储原始透明度
                    if originalOpacityValues[widgetView.cmdString] == nil {
                        originalOpacityValues[widgetView.cmdString] = Float(widgetView.alpha)
                    }
                    
                    // 添加动画效果
                    UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut], animations: {
                        widgetView.alpha = 0.15
                    })
                }
            }
        }
        
        // 然后处理 OnScreenControls 创建的控件
        if let oscButtonLayers = onScreenControls.value(forKey: "OSCButtonLayers") as? [CALayer] {
            for layer in oscButtonLayers {
                if let layerName = layer.name, controlNames.contains(layerName) {
                    // 存储原始透明度
                    if originalOpacityValues[layerName] == nil {
                        originalOpacityValues[layerName] = layer.opacity
                    }
                    
                    // 添加动画效果
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.2)
                    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
                    layer.opacity = 0.15
                    CATransaction.commit()
                }
            }
        }
    }
    
    // 恢复所有控件的透明度
    private func restoreControlsOpacity() {
        guard let superview = self.superview else { return }
        
        // 首先恢复 OnScreenWidgetView 创建的控件
        for subview in superview.subviews {
            if let widgetView = subview as? OnScreenWidgetView {
                if let originalOpacity = originalOpacityValues[widgetView.cmdString] {
                    // 添加动画效果
                    UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut], animations: {
                        widgetView.alpha = CGFloat(originalOpacity)
                    })
                }
            }
        }
        
        // 然后恢复 OnScreenControls 创建的控件
        if let oscButtonLayers = onScreenControls.value(forKey: "OSCButtonLayers") as? [CALayer] {
            for layer in oscButtonLayers {
                if let layerName = layer.name, let originalOpacity = originalOpacityValues[layerName] {
                    // 添加动画效果
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.2)
                    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
                    layer.opacity = originalOpacity
                    CATransaction.commit()
                }
            }
        }
        
        // 清空存储的透明度值
        originalOpacityValues.removeAll()
    }
    
    @objc public func resizeWidgetView(){
        guard let superview = superview else { return }
        
        
        // Deactivate existing constraints if necessary
        NSLayoutConstraint.deactivate(self.constraints)
        
        // To resize the button, we must set this to false temporarily
        translatesAutoresizingMaskIntoConstraints = false
                
        // replace invalid factor values
        if self.widthFactor == 0 {self.widthFactor = 1.0}
        if self.heightFactor == 0 {self.heightFactor = 1.0}
        
        /*
        NSLayoutConstraint.activate([
            self.centerXAnchor.constraint(equalTo: self.superview!.leadingAnchor, constant: storedLocation.x),
            self.centerYAnchor.constraint(equalTo: self.superview!.topAnchor, constant: storedLocation.y)])
         */
        

        // Constraints for resizing
        self.changeAndActivateContraints()
        
        // Trigger layout update
        superview.layoutIfNeeded()
        
        // Re-setup widgetView style
        setupView()
    }
    
    private func tweakAlpha(){
        // setup default border from self.backgroundAlpha
        let realBackgroundAlpha = self.backgroundAlpha - 0.18 // offset to be consistent with legacy onScreen controller layer opacity
        self.backgroundColor = UIColor(white: 0.2, alpha: realBackgroundAlpha) // offset to be consistent with legacy onScreen controller layer opacity
        var borderAlpha = realBackgroundAlpha * 1.01
        if widgetType == WidgetTypeEnum.touchPad {
           minimumBorderAlpha = 0.0
        }
        if borderAlpha < minimumBorderAlpha {
            borderAlpha = minimumBorderAlpha
        }
        defaultBorderColor = UIColor(white: 0.2, alpha: borderAlpha).cgColor
        self.layer.borderColor = defaultBorderColor

        if widgetType == WidgetTypeEnum.touchPad {
            self.backgroundColor = UIColor.clear // make touchPad transparent
            self.layer.borderColor = UIColor(white: 0.2, alpha: borderAlpha - 0.15).cgColor // reduced border alpha for touchPad
        }
    }
    
    func nearestEven(_ value: CGFloat) -> CGFloat {
        let rounded = round(value)
        if Int(rounded) % 2 == 0 {
            return rounded
        } else {
            let lowerEven = rounded - 1
            let upperEven = rounded + 1
            return abs(value - lowerEven) <= abs(value - upperEven) ? lowerEven : upperEven
        }
    }
    
    private func denormalizeSize(sizeFactor:CGFloat) -> CGFloat {
        // 使用固定的基准宽度(1194)来避免旋转时的累积变化
        let baseScreenWidth: CGFloat = 1194.0
        // return CGFloat(Int(sizeFactor/10000*baseScreenWidth/2)*2);
        return nearestEven(sizeFactor/10000*baseScreenWidth);
    }
    
    private func changeAndActivateContraints(){
        if self.widgetType == WidgetTypeEnum.fullscreenTrigger {
            if OnScreenWidgetView.editMode {
                // Small visible handle in the editor so the user can tap it (invisible-but-clickable
                // handles are harder to discover). We keep it non-movable in touchesMoved.
                NSLayoutConstraint.activate([
                    self.widthAnchor.constraint(equalToConstant: 320),
                    self.heightAnchor.constraint(equalToConstant: 130),
                ])
            } else if let superview = self.superview {
                // Runtime: cover the entire parent. hitTest returns nil so taps still pass through
                // to the stream view; the double-tap gesture recognizer on superview detects the combo.
                NSLayoutConstraint.activate([
                    self.leadingAnchor.constraint(equalTo: superview.leadingAnchor),
                    self.trailingAnchor.constraint(equalTo: superview.trailingAnchor),
                    self.topAnchor.constraint(equalTo: superview.topAnchor),
                    self.bottomAnchor.constraint(equalTo: superview.bottomAnchor),
                ])
            }
            self.deNormalizedWidthFactor = 1.0
            self.deNormalizedHeightFactor = 1.0
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                outlineLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                outlineLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            self.layer.cornerRadius = OnScreenWidgetView.editMode ? 12 : 0
            return
        }

        let isNormalizedSizeFactor = self.widthFactor > 6;

        if self.shape == "round"{ // we'll make custom osc buttons round & smaller
            NSLayoutConstraint.activate([
                self.widthAnchor.constraint(equalToConstant: isNormalizedSizeFactor ? denormalizeSize(sizeFactor:self.widthFactor) : CGFloat(Int(60 * self.widthFactor / 2) * 2)),
                self.heightAnchor.constraint(equalToConstant: isNormalizedSizeFactor ? denormalizeSize(sizeFactor:self.widthFactor) : CGFloat(Int(60 * self.widthFactor / 2) * 2)),])
            self.deNormalizedWidthFactor = isNormalizedSizeFactor ? denormalizeSize(sizeFactor:self.widthFactor)/60 : self.widthFactor;
            self.deNormalizedHeightFactor = isNormalizedSizeFactor ? denormalizeSize(sizeFactor:self.widthFactor)/60 : self.widthFactor;
        }
        if self.shape == "square" {
            NSLayoutConstraint.activate([
                self.widthAnchor.constraint(equalToConstant: isNormalizedSizeFactor ? denormalizeSize(sizeFactor:self.widthFactor) :  CGFloat(Int(70 * self.widthFactor / 2) * 2)),
                self.heightAnchor.constraint(equalToConstant: isNormalizedSizeFactor ? denormalizeSize(sizeFactor:self.heightFactor) :  CGFloat(Int(65 * self.heightFactor / 2) * 2)),])
            self.deNormalizedWidthFactor = isNormalizedSizeFactor ? denormalizeSize(sizeFactor:self.widthFactor)/70 : self.widthFactor;
            self.deNormalizedHeightFactor = isNormalizedSizeFactor ? denormalizeSize(sizeFactor:self.heightFactor)/65 : self.heightFactor;
        }
        if self.shape == "largeSquare" { // override all shape strings
            NSLayoutConstraint.activate([
                self.widthAnchor.constraint(equalToConstant:isNormalizedSizeFactor ? denormalizeSize(sizeFactor:self.widthFactor) :  CGFloat(Int(170 * self.widthFactor / 2) * 2)),
                self.heightAnchor.constraint(equalToConstant:isNormalizedSizeFactor ? denormalizeSize(sizeFactor:self.heightFactor) :  CGFloat(Int(150 * self.heightFactor / 2) * 2)),])
            self.deNormalizedWidthFactor = isNormalizedSizeFactor ? denormalizeSize(sizeFactor:self.widthFactor)/170 : self.widthFactor;
            self.deNormalizedHeightFactor = isNormalizedSizeFactor ? denormalizeSize(sizeFactor:self.heightFactor)/150 : self.heightFactor;
        }

        NSLayoutConstraint.activate([
            outlineLabel.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 10),
            outlineLabel.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -10),
            outlineLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            outlineLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 10), // set up label size contrain within UIView
            label.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -10),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),])
        
        if self.shape != "round"{
            let shortSideLen = min(self.layer.bounds.size.width, self.layer.bounds.size.height)
            self.layer.cornerRadius = shortSideLen/2 < 16 ? shortSideLen/3.2 : 16
        }
    }
    
    private func setupView() {
        if self.widgetType == WidgetTypeEnum.fullscreenTrigger {
            setupFullscreenTriggerView()
            return
        }
        label.text = self.buttonLabel
        label.font = roundedBoldFont(ofSize: 19)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.1  // Adjust the scale factor as needed
        
        label.textColor = UIColor(white: 1.0, alpha: max(0.0, min(textAlpha, 1.0)))
        label.textAlignment = .center
        label.shadowColor = nil
        label.shadowOffset = .zero
        label.translatesAutoresizingMaskIntoConstraints = false // enable auto alignment for the label

        // setup outline label (stroke-only behind main label)
        outlineLabel.text = self.buttonLabel
        outlineLabel.font = label.font
        outlineLabel.translatesAutoresizingMaskIntoConstraints = false
        outlineLabel.adjustsFontSizeToFitWidth = true
        outlineLabel.minimumScaleFactor = label.minimumScaleFactor
        outlineLabel.textAlignment = .center
        outlineLabel.textColor = .clear
        outlineLabel.shadowColor = nil
        outlineLabel.shadowOffset = .zero
        
        self.translatesAutoresizingMaskIntoConstraints = true // this is mandatory to prevent unexpected key view location change
        
        self.layer.cornerRadius = 16
        self.layer.borderWidth = self.borderWidth

        self.tweakAlpha()
        
        if self.shape == "default" || self.shape.isEmpty {
            if CommandManager.oscButtonMappings.keys.contains(self.buttonString) && !CommandManager.oscRectangleButtonCmds.contains(self.buttonString){ //make oscButtons round
                self.shape = "round"
            }
            else {
                self.shape = "square"
            }
        }
        
        if self.widgetType == WidgetTypeEnum.touchPad {
            self.shape = "largeSquare" // override shape from user input
            if(self.borderWidth < 1) {self.layer.borderWidth = 1}
            else {self.layer.borderWidth = self.borderWidth}
            label.text = "" // make touchPad display no text
            if OnScreenWidgetView.editMode { //display label in edit mode to make the pad more visible
                label.text = self.buttonLabel
            }
        }

        if CommandManager.specialOverlayButtonCmds.contains(self.cmdString){
            self.layer.borderWidth = 0
        }

        if self.shape == "round" {
            //setup round buttons
            self.layer.cornerRadius = self.frame.width/2
            // self.layer.borderWidth = self.borderWidth
            label.minimumScaleFactor = 0.15  // Adjust the scale factor for oscButtons
            label.font = roundedBoldFont(ofSize: 22)
            outlineLabel.font = label.font
        }
        if self.shape == "square" || self.shape == "largeSquare" {
            //just do nothing here
        }

        // Ensure subview order: outline behind, label on top
        if outlineLabel.superview !== self { self.addSubview(outlineLabel) }
        if label.superview !== self { self.addSubview(label) }
        self.bringSubviewToFront(label)
        applyLabelStroke()
        
        // self.layer.shadowColor = UIColor.clear.cgColor
        // self.layer.shadowRadius = 8
        // self.layer.shadowOpacity = 0.5
        
        self.changeAndActivateContraints()
        
        center = storedCenter //anchor the center while resizing self
        
        setupButtonDownVisualEffectLayer();
        if CommandManager.directionPads.contains(touchPadString) {setupLrudDirectionIndicatorlayers()}
        if CommandManager.stickTouchPads.contains(touchPadString) {self.l3r3Indicator = createl3r3Indicator()}
        if self.hasStickIndicator {
            if self.crossMarkLayer.superlayer == nil {self.crossMarkLayer = createCrossMark()}
            if self.stickBallLayer.superlayer == nil {self.stickBallLayer = createStickBall()}
        }
    }

    private let fullscreenEditBorderLayer = CAShapeLayer()
    private weak var fullscreenDoubleTapGesture: UITapGestureRecognizer?
    private weak var attachedFullscreenGestureToSuperview: UIView?

    // Mistouch buffer (pt) added around every sibling widget and OSC layer when deciding
    // whether the fullscreen-trigger double-tap should fire. Only suppresses the fullscreen
    // gesture; never widens any other control's actual hit area.
    private static let fullscreenMistouchBuffer: CGFloat = 15

    private func setupFullscreenTriggerView() {
        self.translatesAutoresizingMaskIntoConstraints = false
        self.layer.borderWidth = 0
        self.layer.borderColor = UIColor.clear.cgColor

        let displayText = self.buttonLabel.isEmpty ? self.cmdString : self.buttonLabel
        label.text = OnScreenWidgetView.editMode ? "\(displayText) — double-tap trigger" : ""
        label.font = roundedBoldFont(ofSize: 22)
        label.textColor = UIColor(white: 1.0, alpha: 0.85)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.3
        label.translatesAutoresizingMaskIntoConstraints = false

        outlineLabel.text = label.text
        outlineLabel.font = label.font
        outlineLabel.textAlignment = .center
        outlineLabel.adjustsFontSizeToFitWidth = true
        outlineLabel.minimumScaleFactor = 0.3
        outlineLabel.translatesAutoresizingMaskIntoConstraints = false

        if outlineLabel.superview !== self { self.addSubview(outlineLabel) }
        if label.superview !== self { self.addSubview(label) }
        self.bringSubviewToFront(label)
        applyLabelStroke()

        updateFullscreenEditAppearance()

        if OnScreenWidgetView.editMode {
            // In edit mode, mirror the pattern used by other widget types: width/height set via
            // Auto Layout (inside changeAndActivateContraints), then switch to frame-based
            // positioning so `center = storedCenter` drives the handle location.
            self.translatesAutoresizingMaskIntoConstraints = true
            self.changeAndActivateContraints()
            center = storedCenter
        } else {
            // Runtime: edge constraints anchor the widget to the superview's 4 sides so it covers
            // the full stream area. Leave translatesAutoresizingMaskIntoConstraints = false so the
            // constraints remain authoritative.
            self.translatesAutoresizingMaskIntoConstraints = false
            self.changeAndActivateContraints()
        }
    }

    private func updateFullscreenEditAppearance() {
        if OnScreenWidgetView.editMode {
            if fullscreenEditBorderLayer.superlayer == nil {
                self.layer.addSublayer(fullscreenEditBorderLayer)
            }
            fullscreenEditBorderLayer.strokeColor = UIColor(white: 1.0, alpha: 0.55).cgColor
            fullscreenEditBorderLayer.fillColor = UIColor.clear.cgColor
            fullscreenEditBorderLayer.lineWidth = 2.5
            fullscreenEditBorderLayer.lineDashPattern = [10, 6]
            self.backgroundColor = UIColor(white: 0.1, alpha: 0.12) // slight tint so editor users can see it
            layoutFullscreenEditBorder()
        } else {
            fullscreenEditBorderLayer.removeFromSuperlayer()
            self.backgroundColor = .clear
        }
    }

    private func layoutFullscreenEditBorder() {
        guard fullscreenEditBorderLayer.superlayer != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset: CGFloat = 3
        fullscreenEditBorderLayer.frame = self.bounds
        fullscreenEditBorderLayer.path = UIBezierPath(rect: self.bounds.insetBy(dx: inset, dy: inset)).cgPath
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if widgetType == WidgetTypeEnum.fullscreenTrigger {
            layoutFullscreenEditBorder()
        }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if widgetType == WidgetTypeEnum.fullscreenTrigger {
            if superview == nil {
                detachFullscreenGesture()
            } else {
                attachFullscreenGestureIfNeeded()
            }
        }
    }

    private func attachFullscreenGestureIfNeeded() {
        // Only attach the gesture recognizer in runtime (not edit mode).
        // In edit mode, the widget is hit-testable for tap-to-select via its own touchesBegan;
        // in runtime, the widget returns nil from hitTest, so double-tap detection must live
        // on the superview (streamFrameTopLayerView), which is what actually receives touches.
        if OnScreenWidgetView.editMode {
            detachFullscreenGesture()
            return
        }
        guard let superview = self.superview else { return }
        if attachedFullscreenGestureToSuperview === superview, fullscreenDoubleTapGesture != nil {
            return
        }
        detachFullscreenGesture()
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleFullscreenDoubleTap(_:)))
        tap.numberOfTapsRequired = 2
        tap.numberOfTouchesRequired = 1
        // Finger-only: a pencil double-tap on the stream must not open the widget
        // editor, and (cancelsTouchesInView) must never cancel in-flight pencil input.
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.cancelsTouchesInView = true
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        superview.addGestureRecognizer(tap)
        fullscreenDoubleTapGesture = tap
        attachedFullscreenGestureToSuperview = superview
    }

    private func detachFullscreenGesture() {
        if let tap = fullscreenDoubleTapGesture, let host = attachedFullscreenGestureToSuperview {
            host.removeGestureRecognizer(tap)
        }
        fullscreenDoubleTapGesture = nil
        attachedFullscreenGestureToSuperview = nil
    }

    @objc private func handleFullscreenDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard !OnScreenWidgetView.editMode else { return }
        guard !OnScreenWidgetView.gesturesSuppressed else { return }
        if vibrationOn {
            vibrationGenerator.prepare()
            vibrationGenerator.impactOccurred()
        }
        let strings = self.comboButtonStrings
        if !strings.isEmpty {
            self.sendComboButtonsDownEvent(comboStrings: strings)
            DispatchQueue.global(qos: .userInteractive).async {
                usleep(100000)
                self.sendComboButtonsUpEvent(comboStrings: strings)
            }
        } else if self.cmdString.contains("+") && !self.cmdString.contains("-") {
            if let keyboardCmdStrings = CommandManager.shared.extractKeyStringsFromComboCommand(from: self.cmdString) {
                CommandManager.shared.sendKeyComboCommand(keyboardCmdStrings: keyboardCmdStrings)
            }
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if widgetType == WidgetTypeEnum.fullscreenTrigger && !OnScreenWidgetView.editMode {
            // Transparent to hit-testing in runtime: taps pass through to the stream view below.
            // Double-taps are caught by the gesture recognizer attached to superview.
            return nil
        }
        if widgetType == WidgetTypeEnum.touchPad && !OnScreenWidgetView.editMode {
            // Pad widgets sit visually below the legacy OSC CALayers (StreamView's
            // reloadOnScreenWidgetViews slots them between the fullscreen trigger and
            // the OSC layer band — see the two-pass attach there). Make touch routing
            // match: if the touch lands inside a visible legacy OSC button rect,
            // return nil so it falls through to StreamView's touchesBegan, which then
            // forwards to onScreenControls.handleTouchDownEvent for proper dispatch.
            //
            // Same pattern the fullscreen trigger uses above, just gated on overlap
            // with a real OSC button instead of unconditional. In edit mode we keep
            // the default behavior so the user can still tap-select and drag pads.
            if let superview = self.superview {
                let pointInSuper = self.convert(point, to: superview)
                if onScreenControls.pointHitsAnyVisibleLegacyOscButton(pointInSuper) {
                    return nil
                }
            }
        }
        return super.hitTest(point, with: event)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === fullscreenDoubleTapGesture else { return true }
        guard let superview = self.superview else { return true }
        let locationInSuper = touch.location(in: superview)

        // Left/right edge strips are gesture country (right-edge OSC toggle,
        // slide-to-settings): a short edge swipe still fits inside a tap
        // recognizer's movement tolerance, so two rapid swipes read as a double
        // tap and fired this widget's combo. The old right-edge pre-suppression
        // masked that by accident; exempt the strips deterministically instead.
        let edgeStrip: CGFloat = 24
        if locationInSuper.x < edgeStrip || locationInSuper.x > superview.bounds.width - edgeStrip {
            return false
        }

        // 1) Reject if a sibling UIControl (snap-ratio toggle, OSC on/off, etc.) or another
        // widget view would handle the touch. superview.hitTest recursively finds what UIKit
        // would actually deliver this touch to; the fullscreen widget's own hitTest returns
        // nil at runtime so the result is always something *other than* self. (Plain UIView
        // siblings with their own recognizers aren't covered here — none exist today; widen
        // this branch if such a sibling is added later.)
        if let hit = superview.hitTest(locationInSuper, with: nil) {
            if hit is UIControl { return false }                         // any UIButton / segmented control / slider, etc.
            if let widget = hit as? OnScreenWidgetView,
               widget !== self,
               widget.widgetType != WidgetTypeEnum.fullscreenTrigger {
                return false                                              // another widget view will handle the double-tap
            }
        }

        // 2) Reject when the touch lands on a legacy OnScreenControls CALayer (stick,
        // ABXY, bumpers, triggers, dpad, …). Those layers are sublayers of the same
        // superview and don't appear in `superview.subviews`. OnScreenControls itself
        // hit-tests against `presentationLayer`, so we mirror that to stay consistent
        // when layers are mid-animation (e.g., scale/opacity tweens during press).
        if let oscButtonLayers = onScreenControls.value(forKey: "OSCButtonLayers") as? [CALayer] {
            for layer in oscButtonLayers {
                if layer.isHidden { continue }
                let geom = layer.presentation() ?? layer
                let pointInLayer = superview.layer.convert(locationInSuper, to: geom)
                if geom.contains(pointInLayer) {
                    return false
                }
            }
        }

        // 3) Mistouch buffer: also reject when the touch falls within a fixed-pt ring just
        // outside any sibling widget or OSC layer. The buffer only suppresses this
        // fullscreen-trigger gesture — it never widens the underlying control's own hit
        // area, so a tap inside another widget's buffer that also lands inside a third
        // widget's actual hit area still triggers that third widget normally.
        // Note: don't skip on alpha — obscured-mode widgets/layers run at OBSCURED_ALPHA
        // (~0.02) but stay interactive, so they still need the mistouch ring.
        let buffer = OnScreenWidgetView.fullscreenMistouchBuffer
        for case let widget as OnScreenWidgetView in superview.subviews {
            if widget === self { continue }
            if widget.widgetType == WidgetTypeEnum.fullscreenTrigger { continue }
            if widget.isHidden { continue }
            if widget.frame.insetBy(dx: -buffer, dy: -buffer).contains(locationInSuper) {
                return false
            }
        }
        if let oscButtonLayers = onScreenControls.value(forKey: "OSCButtonLayers") as? [CALayer] {
            for layer in oscButtonLayers {
                if layer.isHidden { continue }
                if layer.superlayer == nil { continue } // matches isInDeadZone gating in OnScreenControls
                let geom = layer.presentation() ?? layer
                if geom.frame.insetBy(dx: -buffer, dy: -buffer).contains(locationInSuper) {
                    return false
                }
            }
        }

        return true
    }

    private func roundedBoldFont(ofSize size: CGFloat) -> UIFont {
        var base = UIFont.systemFont(ofSize: size, weight: .bold)
        if #available(iOS 13.0, *), let rounded = base.fontDescriptor.withDesign(.rounded) {
            base = UIFont(descriptor: rounded, size: size)
        }
        return base
    }

    private func applyLabelStroke() {
        let text = label.text ?? ""
        let font = label.font ?? roundedBoldFont(ofSize: 19)
        // 使用正值描边宽度绘制仅描边（无填充），再由上层 label 负责填充，从而呈现外描边
        let pointSize = max(font.pointSize, 1)
        let strokeWidthPercent = (1.5 / pointSize) * 100.0
        let alphaScale = defaultLabelTextAlpha > 0 ? max(0.0, min(textAlpha, 1.0)) / defaultLabelTextAlpha : 1.0
        let strokeAlpha = min(1.0, defaultLabelStrokeAlpha * alphaScale)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.clear,
            .strokeColor: UIColor(white: 0.0, alpha: strokeAlpha),
            .strokeWidth: strokeWidthPercent
        ]
        outlineLabel.attributedText = NSAttributedString(string: text, attributes: attributes)
    }

    private func applyLabelTextAppearance() {
        label.textColor = UIColor(white: 1.0, alpha: max(0.0, min(textAlpha, 1.0)))
        applyLabelStroke()
    }
    
    private func createl3r3Indicator() -> CAShapeLayer{
        let indicatorFrame = CAShapeLayer();
        let indicatorBorder = CAShapeLayer();
        
        indicatorFrame.frame = CGRectMake(0, 0, 75, 75)
        indicatorFrame.cornerRadius = 9
        indicatorBorder.borderWidth = 7
        indicatorBorder.frame = indicatorFrame.bounds.insetBy(dx: -indicatorBorder.borderWidth, dy: -indicatorBorder.borderWidth) // Adjust the inset as needed
        indicatorBorder.borderColor = UIColor.clear.cgColor
        
        indicatorBorder.cornerRadius = indicatorFrame.cornerRadius + indicatorBorder.borderWidth
        indicatorBorder.backgroundColor = UIColor.clear.cgColor
        indicatorBorder.fillColor = UIColor.clear.cgColor
        let path = UIBezierPath(roundedRect: indicatorBorder.bounds, cornerRadius: indicatorBorder.cornerRadius)
        indicatorBorder.path = path.cgPath
        indicatorBorder.borderColor = UIColor.clear.cgColor
        
        self.layer.superlayer?.addSublayer(indicatorBorder)

        return indicatorBorder
    }

    private func showl3r3Indicator(){
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        self.l3r3Indicator.borderColor = buttonHighlightCGColor
        self.l3r3Indicator.position = CGPointMake(CGRectGetMinX(self.frame)+touchBeganLocation.x, CGRectGetMinY(self.frame)+touchBeganLocation.y)
        
        CATransaction.commit()
        
        if vibrationOn {
            vibrationGenerator.prepare()
            vibrationGenerator.impactOccurred()
        }
    }

    private var shouldTriggerQuickDoubleTapCombo: Bool {
        guard quickDoubleTapDetected, !comboButtonStrings.isEmpty else { return false }
        return !hasDoubleTapStickClickTweak || doubleTapStickClickEnabled
    }

    private func recordAltStickDoubleTapMovement(to currentLocation: CGPoint) {
        guard isAltStickPad, !altStickTouchMovedBeyondTapSlop else { return }
        let movement = hypot(currentLocation.x - touchBeganLocation.x,
                             currentLocation.y - touchBeganLocation.y)
        if movement > ALT_STICK_DOUBLE_TAP_STATIONARY_SLOP {
            altStickTouchMovedBeyondTapSlop = true
            // The touch turned into a drag: this was stick movement, not the
            // second half of a double-click. Drop the deferred stick-click.
            pendingDoubleTapComboWork?.cancel()
            pendingDoubleTapComboWork = nil
        }
    }

    private func finishAltStickDoubleTapMovementTracking(cancelled: Bool = false) {
        guard isAltStickPad else { return }
        lastAltStickTouchWasStationaryTap = !cancelled && !altStickTouchMovedBeyondTapSlop && !altStickTouchHadMultipleTouches
        altStickTouchMovedBeyondTapSlop = false
        altStickTouchHadMultipleTouches = false
    }

    private func triggerQuickDoubleTapCombo(showIndicator: Bool = true) {
        guard shouldTriggerQuickDoubleTapCombo else { return }
        if isAltStickPad {
            // See altDoubleTapConfirmDelay: hold fire until the touch proves it's a
            // tap, not the start of a stick stroke. recordAltStickDoubleTapMovement
            // cancels on movement; releaseQuickDoubleTapComboIfNeeded(fireIfPending:)
            // converts an early lift into a clean click.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingDoubleTapComboWork = nil
                guard self.touchBegan,
                      !self.altStickTouchMovedBeyondTapSlop,
                      !self.altStickTouchHadMultipleTouches else { return }
                self.fireQuickDoubleTapCombo(showIndicator: showIndicator)
            }
            pendingDoubleTapComboWork?.cancel()
            pendingDoubleTapComboWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + OnScreenWidgetView.altDoubleTapConfirmDelay, execute: work)
            return
        }
        fireQuickDoubleTapCombo(showIndicator: showIndicator)
    }

    private func fireQuickDoubleTapCombo(showIndicator: Bool) {
        if showIndicator {
            self.showl3r3Indicator()
        }
        self.sendComboButtonsDownEvent(comboStrings: self.comboButtonStrings)
        self.quickDoubleTapComboHeld = true
    }

    private func releaseQuickDoubleTapComboIfNeeded(fireIfPending: Bool = false) {
        if let pending = pendingDoubleTapComboWork {
            pending.cancel()
            pendingDoubleTapComboWork = nil
            // Lifted inside the confirmation window without moving: a genuine quick
            // double-tap. Deliver the click as a short press+release. Cancel paths
            // (fireIfPending == false) just drop the pending click.
            if fireIfPending && !altStickTouchMovedBeyondTapSlop && !altStickTouchHadMultipleTouches {
                let strings = self.comboButtonStrings
                sendComboButtonsDownEvent(comboStrings: strings)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    // Intentionally strong capture: the UP must fire even if the
                    // widget is removed within the 50ms window — a dropped release
                    // would leave the stick-click token stuck host-side.
                    self.sendComboButtonsUpEvent(comboStrings: strings)
                }
                return
            }
        }
        guard quickDoubleTapComboHeld else { return }
        sendComboButtonsUpEvent(comboStrings: comboButtonStrings)
        quickDoubleTapComboHeld = false
    }

    
    //================================================================================================
    //Indicator overlay for on-screen game controller left or right sticks (non-vector mode)
    
    private func handleStickBallReachingBorder(){
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stickBallLayer.lineWidth = 0.6
        // stickBallLayer.shadowOffset = CGSize(width: 0.0, height: 0.0)
        stickBallLayer.shadowOffset = CGSize(width: 0.0, height: 0.0)
        // stickBallLayer.shadowColor = stickBallLayer.strokeColor
        CATransaction.commit()
    }

    private func handleStickBallLeavingBorder(){
        stickBallLayer.lineWidth = 0
        stickBallLayer.shadowOffset = CGSize(width: 0.5, height: 0.5)
        stickBallLayer.shadowOpacity = 0.8
        stickBallLayer.shadowColor = UIColor.black.cgColor
    }
    
    // create stick indicator: the crossMark & stickBall:
    @objc public func showStickIndicator(){
        // tell if the self button is located on the left or right
        // self.selfViewOnTheRight = (self.storedCenter.x > self.appWindow.frame.width*0.5), deprecated
        // let offsetSign = selfViewOnTheRight ? -1 : 1
        let stickMarkerRelativeLocation:CGPoint
        if !OnScreenWidgetView.editMode {
            stickMarkerRelativeLocation = CGPointMake(touchBeganLocation.x, touchBeganLocation.y - self.stickIndicatorOffset)
        }
        else{
            stickMarkerRelativeLocation = CGPointMake(touchBeganLocation.x, touchBeganLocation.y)
        }
        
        if self.touchPadString == "LSPADALT" {
            // ALT 自有指示器，不创建十字或小球
            showStickBall(at: stickMarkerRelativeLocation)
            self.crossMarkLayer.isHidden = true
        } else {
            showStickBall(at: stickMarkerRelativeLocation)
            showCrossMarkOnTouchPoint(at: stickMarkerRelativeLocation)
        }
    }
    
    // cross mark for left & right gamePad
    private func createCrossMark() -> CAShapeLayer {
        let crossLayer = CAShapeLayer()
        
        crossLayer.strokeColor = crossMarkColor
        crossLayer.lineWidth = 1.2
        crossLayer.fillColor = crossMarkColor
        
        self.layer.superlayer?.addSublayer(crossLayer)
        crossLayer.shadowColor = UIColor.black.cgColor
        crossLayer.shadowOffset = CGSize(width: 1, height: 1)
        crossLayer.shadowRadius = 0;
        crossLayer.shadowOpacity = 0.8
        
        crossLayer.isHidden = true
        
        return crossLayer
    }
    
    private func showCrossMarkOnTouchPoint(at point: CGPoint) {
        let path = UIBezierPath()
        let crossSize = 26.0
        
        path.move(to: CGPoint(x: point.x - crossSize / 2, y: point.y))
        path.addLine(to: CGPoint(x: point.x + crossSize / 2, y: point.y))
        
        // 竖线
        path.move(to: CGPoint(x: point.x, y: point.y - crossSize / 2))
        path.addLine(to: CGPoint(x: point.x, y: point.y + crossSize / 2))
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        self.crossMarkLayer.path = path.cgPath
        self.crossMarkLayer.position = CGPointMake(CGRectGetMinX(self.frame), CGRectGetMinY(self.frame))
        self.crossMarkLayer.isHidden = false
        
        CATransaction.commit()
    }

    
    private func createStickBall() -> CAShapeLayer {
        // Create a CAShapeLayer
        let stickBallLayer = CAShapeLayer()
        self.layer.superlayer?.addSublayer(stickBallLayer)
                
        // Set the stroke color and width (border of the circle)
        stickBallLayer.strokeColor = UIColor(red: 0.5, green: 0.5, blue: 1.0, alpha: 1.0).cgColor
        //stickBallLayer.
        stickBallLayer.lineWidth = 0
        stickBallLayer.shadowOffset = CGSize(width: 0.5, height: 0.5)
        stickBallLayer.shadowRadius = 0;
        stickBallLayer.shadowOpacity = 0.8
        
        // Set the fill color (inside of the circle)
        stickBallLayer.fillColor = stickBallColor  // Light fill with some transparency
        
        stickBallLayer.isHidden = true
                
        return stickBallLayer
    }

    private func showStickBall(at center: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // ALT 版不显示小球；普通版显示
        if self.isAltStickPad {
            self.stickBallLayer.isHidden = true
        } else {
            let path = UIBezierPath(arcCenter: center, radius: 8, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
            self.stickBallLayer.path = path.cgPath
            self.stickBallLayer.position = CGPointMake(CGRectGetMidX(self.crossMarkLayer.frame), CGRectGetMidY(self.crossMarkLayer.frame))
            self.stickBallLayer.isHidden = false
        }

        // ALT variant: add background + pointer at touch point (replacing cross)
        if self.isAltStickPad {
            altBackgroundLayer.bounds = CGRect(x: 0, y: 0, width: altIndicatorSize, height: altIndicatorSize)
            altBackgroundLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            altBackgroundLayer.contentsScale = UIScreen.main.scale
            altBackgroundLayer.contentsGravity = CALayerContentsGravity.resizeAspect
            altBackgroundLayer.contents = UIImage(named: "StickOuterAlt")?.cgImage
            altBackgroundLayer.position = self.touchBeganPosInSuperLayer
            if altBackgroundLayer.superlayer == nil { self.layer.superlayer?.addSublayer(altBackgroundLayer) }

            altPointerLayer.bounds = CGRect(x: 0, y: 0, width: altIndicatorSize, height: altIndicatorSize)
            altPointerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            altPointerLayer.contentsScale = UIScreen.main.scale
            altPointerLayer.contentsGravity = CALayerContentsGravity.resizeAspect
            altPointerLayer.contents = UIImage(named: "StickInnerAlt")?.cgImage
            altPointerLayer.position = self.touchBeganPosInSuperLayer
            altBackgroundLayer.setAffineTransform(.identity)
            altPointerLayer.setAffineTransform(.identity)
            if altPointerLayer.superlayer == nil { self.layer.superlayer?.addSublayer(altPointerLayer) }
            altBackgroundLayer.isHidden = false
            altPointerLayer.isHidden = false
            altBackgroundLayer.opacity = 0.0
            altPointerLayer.opacity = 0.0
            // fade-in for background & pointer
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            altBackgroundLayer.opacity = 1.0
            altPointerLayer.opacity = 1.0
            CATransaction.commit()
        }
        CATransaction.commit()
    }

    
    @objc public func updateStickIndicator(){
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.stickBallLayer.removeAllAnimations()
        if !OnScreenWidgetView.editMode {
            if self.isAltStickPad {
                let k = CGFloat(18.0)/stickInputScale
                var x = offSetX*sensitivityFactorX * k
                var y = offSetY*sensitivityFactorY * k
                let radius = CGFloat(stickBallMaxOffset)
                let mag = hypot(x, y)
                if mag > radius && mag > 0 {
                    let scale = radius / mag
                    x *= scale
                    y *= scale
                }
                // ALT：每帧基于角度与幅度生成一次性变换，避免累积放大
                if self.isAltStickPad {
                    let angle = atan2(y, x) + .pi/2
                    let normalized = min(hypot(x, y)/CGFloat(stickBallMaxOffset), 1.0)
                    let scale = 1.0 + (altIndicatorMaxScale - 1.0) * normalized
                    let transform = CGAffineTransform(rotationAngle: angle).scaledBy(x: scale, y: scale)
                    altPointerLayer.setAffineTransform(transform)
                    altBackgroundLayer.setAffineTransform(transform)
                    let opacity = Float(0.75 + 0.25 * normalized)
                    altBackgroundLayer.opacity = opacity
                    altPointerLayer.opacity = opacity
                }
                altBackgroundLayer.position = self.touchBeganPosInSuperLayer
                altPointerLayer.position = self.touchBeganPosInSuperLayer
                if hypot(x, y) >= CGFloat(stickBallMaxOffset) {
                    handleStickBallReachingBorder()
                }
                else{
                    handleStickBallLeavingBorder()
                }
            }
            else {
                let realOffsetX = touchInputToStickBallCoord(input: offSetX*sensitivityFactorX)
                let realOffsetY = touchInputToStickBallCoord(input: offSetY*sensitivityFactorY)
                self.stickBallLayer.position = CGPointMake(CGRectGetMidX(self.crossMarkLayer.frame) + realOffsetX, CGRectGetMidY(self.crossMarkLayer.frame) + realOffsetY)
                if fabs(realOffsetX) == stickBallMaxOffset || fabs(realOffsetY) == stickBallMaxOffset {
                    handleStickBallReachingBorder()
                }
                else{
                    handleStickBallLeavingBorder()
                }
            }
        }
        else{
            // illustrate offset distance in edit mode
            // let offsetSign = self.selfViewOnTheRight ? -1 : 1 // dprecated
            // let illlustrationPoint = CGPointMake(CGRectGetMidX(self.frame), CGRectGetMaxY(self.frame)/4)
            self.stickBallLayer.position = CGPointMake(CGRectGetMidX(self.crossMarkLayer.frame), CGRectGetMidY(self.crossMarkLayer.frame)-stickIndicatorOffset)
        }
        CATransaction.commit()
    }
    
    private func resetStickBallPositionAndHideIndicator(){
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        handleStickBallLeavingBorder()
        CATransaction.commit()

        CATransaction.begin()
        // CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0.15)
        if self.isAltStickPad {
            self.stickBallLayer.position = CGPoint(x: CGRectGetMinX(self.frame) + self.touchBeganLocation.x,
                                                   y: CGRectGetMinY(self.frame) + self.touchBeganLocation.y)
            // fade out ALT indicator (background & pointer)
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            altBackgroundLayer.opacity = 0.0
            altPointerLayer.opacity = 0.0
            CATransaction.setCompletionBlock {
                self.altBackgroundLayer.isHidden = true
                self.altPointerLayer.isHidden = true
                self.altPointerLayer.opacity = 0.0
                self.altBackgroundLayer.setAffineTransform(.identity)
                self.altPointerLayer.setAffineTransform(.identity)
            }
            CATransaction.commit()
        }
        else{
            self.stickBallLayer.position = CGPointMake(CGRectGetMidX(self.crossMarkLayer.frame), CGRectGetMidY(self.crossMarkLayer.frame))
        }
        CATransaction.setCompletionBlock {
            DispatchQueue.global().async {
                // 后台执行耗时操作
                usleep(200000)
                DispatchQueue.main.async { // switch to main thread to update UI
                    if !self.touchBegan {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        self.crossMarkLayer.isHidden = true
                        self.stickBallLayer.isHidden = true
                        CATransaction.commit()
                    }
                }
            }
            // 动画结束后执行的代码
        }
        CATransaction.commit()
    }

    private func hideStickIndicatorImmediately() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.crossMarkLayer.isHidden = true
        self.stickBallLayer.isHidden = true
        self.altBackgroundLayer.isHidden = true
        self.altPointerLayer.isHidden = true
        self.altBackgroundLayer.opacity = 0.0
        self.altPointerLayer.opacity = 0.0
        self.altBackgroundLayer.setAffineTransform(.identity)
        self.altPointerLayer.setAffineTransform(.identity)
        CATransaction.commit()
    }
    
    //================================================================================================
    
    
    
    //=====LRUD(left right up & down buttons) touchPad touch =========================================
    
    private func showLrudBall(at point: CGPoint) {
        // Create a circular path using UIBezierPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let path = UIBezierPath(arcCenter: point, radius: 10, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        
        // Create a CAShapeLayer
        lrudIndicatorBall.path = path.cgPath  // Assign the circular path to the shape layer
        
        lrudIndicatorBall.position = CGPointMake(CGRectGetMinX(self.frame), CGRectGetMinY(self.frame))
        lrudIndicatorBall.isHidden = false;
        
        CATransaction.commit()
    }
    
    private func createLrudBall() -> CAShapeLayer {
        // Create a circular path using UIBezierPath
        let path = UIBezierPath(arcCenter: CGPoint(x: 0, y: 0), radius: 10, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        
        // Create a CAShapeLayer
        let ballLayer = CAShapeLayer()
        ballLayer.path = path.cgPath  // Assign the circular path to the shape layer
        self.layer.superlayer?.addSublayer(ballLayer)
        
        // Set the stroke color and width (border of the circle)
        ballLayer.strokeColor = stickBallColor
        ballLayer.lineWidth = 0
        ballLayer.shadowOffset = CGSize(width: 0.5, height: 0.5)
        ballLayer.shadowRadius = 0;
        ballLayer.shadowOpacity = 0.8
        ballLayer.name = "lrudBall"
        ballLayer.isHidden = true
        
        // Set the fill color (inside of the circle)
        ballLayer.fillColor = stickBallColor  // Light fill with some transparency
        return ballLayer
    }
    
    private func createLrudDirectionLayer() -> CAShapeLayer {
        let indicatorFrame = CAShapeLayer();
        let indicatorBorder = CAShapeLayer();
        
        indicatorFrame.frame = CGRectMake(0, 0, 75, 75)
        indicatorFrame.cornerRadius = 9
        indicatorBorder.borderWidth = 6
        indicatorBorder.frame = indicatorFrame.bounds.insetBy(dx: -indicatorBorder.borderWidth, dy: -indicatorBorder.borderWidth) // Adjust the inset as needed
        indicatorBorder.borderColor = UIColor.clear.cgColor
        
        indicatorBorder.cornerRadius = indicatorFrame.cornerRadius + indicatorBorder.borderWidth
        indicatorBorder.backgroundColor = UIColor.clear.cgColor
        indicatorBorder.fillColor = UIColor.clear.cgColor
        let path = UIBezierPath(roundedRect: indicatorBorder.bounds, cornerRadius: indicatorBorder.cornerRadius)
        indicatorBorder.path = path.cgPath
        indicatorBorder.borderColor = buttonHighlightCGColor
        
        return indicatorBorder
    }
    
    private func showLrudDirectionIndicator(with indicatorLayer:CAShapeLayer){
        // Add the border layer below the super layer
        indicatorLayer.borderColor = buttonHighlightCGColor
        
        // show the indicator based on the touchBeganLocation
        indicatorLayer.position = CGPointMake(CGRectGetMinX(self.frame)+touchBeganLocation.x, CGRectGetMinY(self.frame)+touchBeganLocation.y)

        if vibrationOn {
            vibrationGenerator.prepare()
            vibrationGenerator.impactOccurred()
        }
    }
    
    private func handleLrudTouchMove(){
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        let radians  = atan2(-offSetY,offSetX)
        let degrees = radians * 180 / .pi
        let nearZeroPoint = abs(offSetX) < 16/sensitivityFactorX && abs(offSetY) < 16/sensitivityFactorY
        // NSLog("deltaX: %f, detalY: %f", deltaX, deltaY)
        
        
        var pressedButtonMask = 0;
        if abs(degrees) < triggeringAngle {
            // NSLog("button pressed: right")
            pressedButtonMask = pressedButtonMask | Direction.right.rawValue
        }
        if 180.0 - abs(degrees) < triggeringAngle {
            // NSLog("button pressed: left")
            pressedButtonMask = pressedButtonMask | Direction.left.rawValue
        }
        if abs(90.0 - degrees) < triggeringAngle {
            // NSLog("button pressed: up")
            pressedButtonMask = pressedButtonMask | Direction.up.rawValue
        }
        if abs(-90.0 - degrees) < triggeringAngle {
            // NSLog("button pressed: down")
            pressedButtonMask = pressedButtonMask | Direction.down.rawValue
        }
        if nearZeroPoint {pressedButtonMask = 0}
        
        if pressedButtonMask != previousButtonMask || directionPadTouchBegan {
            // Send only TRANSITIONS (bit-diff against the previous mask). The old
            // code re-pressed every still-held direction and re-released every idle
            // one on each change — harmless with idempotent bit-setting, but the
            // controller flags are hold-COUNTED now (pressDownControllerButton), so
            // a re-press without a matching extra release stranded the direction
            // down; keyboard pads also flooded redundant UP events.
            let effectivePreviousMask = directionPadTouchBegan ? 0 : previousButtonMask
            directionPadTouchBegan = false
            let directions: [(Direction, CAShapeLayer, String, String, Int32)] = [
                (.up, upIndicator, "W", "UP_ARROW", UP_FLAG),
                (.down, downIndicator, "S", "DOWN_ARROW", DOWN_FLAG),
                (.left, leftIndicator, "A", "LEFT_ARROW", LEFT_FLAG),
                (.right, rightIndicator, "D", "RIGHT_ARROW", RIGHT_FLAG),
            ]
            for (direction, indicator, wasdKey, arrowKey, dpadFlag) in directions {
                let isDown = pressedButtonMask & direction.rawValue == direction.rawValue
                if isDown {
                    showLrudDirectionIndicator(with: indicator)
                } else {
                    indicator.borderColor = UIColor.clear.cgColor
                }
                let wasDown = effectivePreviousMask & direction.rawValue == direction.rawValue
                guard isDown != wasDown else { continue }
                switch touchPadString {
                case "WASDPAD":
                    LiSendKeyboardEvent(CommandManager.keyboardButtonMappings[wasdKey]!, Int8(isDown ? KEY_ACTION_DOWN : KEY_ACTION_UP), 0)
                case "ARROWPAD":
                    LiSendKeyboardEvent(CommandManager.keyboardButtonMappings[arrowKey]!, Int8(isDown ? KEY_ACTION_DOWN : KEY_ACTION_UP), 0)
                case "DPAD":
                    if isDown { self.onScreenControls.pressDownControllerButton(dpadFlag) }
                    else { self.onScreenControls.releaseControllerButton(dpadFlag) }
                default: break
                }
            }
        }

        previousButtonMask = pressedButtonMask
        
        CATransaction.commit()
    }
    //================================================================================================
    
    
    //===== MOUSEPAD related methods=============================================================
    private func sendLongMouseLeftButtonClickEvent() {
        DispatchQueue.global(qos: .userInteractive).async {
            // Logging the press event
            NSLog("Sending left mouse button press")
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), BUTTON_LEFT)

            // Wait 200 ms to simulate a real button press
            usleep(UInt32(self.QUICK_TAP_TIME_INTERVAL * 1000000))

            // If quick tap is not detected, release the button
            if !self.quickDoubleTapDetected {
                LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), BUTTON_LEFT)
                // NSLog("double click: first long click release")
            }
            else{NSLog("Left mouse button release cancelled, keep pressing down, turning into dragging...")}
            // Don't release the button if we're still dragging, this will prevent the dragging from being interrupted.
        }
    }

    private func sendShortMouseLeftButtonClickEvent() {
        DispatchQueue.global(qos: .userInteractive).async {
            NSLog("double click: sending short click")
            usleep(UInt32(50 * 1000))
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), BUTTON_LEFT)
            usleep(UInt32(50 * 1000))
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), BUTTON_LEFT)
        }
    }
    
    private func sendMouseRightButtonClickEvent() {
        DispatchQueue.global(qos: .userInteractive).async {
            usleep(UInt32(50 * 1000))
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), BUTTON_RIGHT)
            usleep(UInt32(50 * 1000))
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), BUTTON_RIGHT)
        }
    }
    
    //mousepad-trackball behavior========================================================
     private func startTrackballMomentum() {
         stopTrackballMomentum()

         trackballDecelerationTimer = Timer.scheduledTimer(withTimeInterval: 1/60, repeats: true) { [weak self] _ in
             guard let self = self else { return }

             LiSendMouseMoveEvent(
                 Int16(truncatingIfNeeded: Int(self.trackballVelocity.x)),
                 Int16(truncatingIfNeeded: Int(self.trackballVelocity.y))
             )

             self.trackballVelocity.x *= self.trackballDecelerationRate
             self.trackballVelocity.y *= self.trackballDecelerationRate

             if abs(self.trackballVelocity.x) < self.trackballVelocityThreshold &&
                abs(self.trackballVelocity.y) < self.trackballVelocityThreshold {
                 self.stopTrackballMomentum()
             }
         }
     }

     private func stopTrackballMomentum() {
         trackballDecelerationTimer?.invalidate()
         trackballDecelerationTimer = nil
     }

    
    // Per-widget motion-button state — guards against double push or unmatched pop
    // (touchesCancelled, gesture-suppression cleanup, etc.). Always paired through
    // these two methods; the underlying ControllerSupport counters stay balanced.
    private var motionButtonHeld: Bool = false

    // Gyro is tied to the button hold and is per-branch (the resolved output's motion token):
    // a conditional widget can have gyro in its armed output but not its base. Latch the one
    // we turned on so the matching up turns off the same one.
    private func activateMotion(_ motion: String) {
        guard !motion.isEmpty, !self.motionButtonHeld else { return }
        switch motion {
        case "GYRO":      self.onScreenControls.pushMotionButtonHold()
        case "GYROPAUSE": self.onScreenControls.pushMotionButtonPause()
        default: return
        }
        self.motionButtonHeld = true
        self.heldMotionString = motion
    }

    private func deactivateMotion() {
        guard self.motionButtonHeld, !self.heldMotionString.isEmpty else { return }
        switch self.heldMotionString {
        case "GYRO":      self.onScreenControls.popMotionButtonHold()
        case "GYROPAUSE": self.onScreenControls.popMotionButtonPause()
        default: break
        }
        self.motionButtonHeld = false
        self.heldMotionString = ""
    }

    //==== wholeButtonPress visual effect=============================================
    private func handleButtonDown() {
        if !OnScreenWidgetView.editMode && !CommandManager.specialOverlayButtonCmds.contains(self.cmdString) {
            // Resolve + fire only on the FIRST touch of a press cycle. A button can receive
            // several handleButtonDown calls (multi-finger, or slide-in from handleButtonSliding)
            // before its matching up; re-resolving on a later touch could latch a different
            // branch than button-up will release, stranding a key down. heldDispatchStrings != nil
            // means "already held", so later touches no-op here (the key is already down) — the
            // same idempotent multi-touch result non-conditional buttons already produced.
            if self.heldDispatchStrings == nil {
                // Pick base vs armed output, and latch it so button-up releases the same set.
                let dispatch = self.resolveDispatch()
                self.heldDispatchStrings = dispatch.strings
                self.heldDispatchIntervalMs = dispatch.intervalMs
                self.sendComboButtonsDownEvent(comboStrings: dispatch.strings, tapFlags: dispatch.taps, intervalMs: dispatch.intervalMs)
                // Record what was actually emitted so a conditional widget pressed next can arm
                // off it (this is also what powers the single-press cascade). Main-thread write.
                // Skip empty dispatches (e.g. legacy "+" combos) so they don't wipe the arm state.
                if !dispatch.strings.isEmpty {
                    CommandManager.shared.recordLastActivationTokens(dispatch.strings)
                }
                self.activateMotion(dispatch.motion)
                // Mirror the press onto the matching legacy OSC button(s) — visual only.
                // Buttons only (touchpads / sticks never run handleButtonDown); a no-op when
                // the legacy button isn't currently shown (guarded in OnScreenControls).
                if self.widgetType == WidgetTypeEnum.button {
                    for token in dispatch.strings {
                        self.onScreenControls.mirrorLegacyButtonHighlight(forString: token, pressed: true)
                    }
                }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // self.layer.borderWidth = 0
        buttonDownVisualEffectLayer.position = CGPointMake(CGRectGetMidX(self.frame), CGRectGetMidY(self.frame)) // update position every time we press down the button
        buttonDownVisualEffectLayer.borderWidth = self.buttonDownVisualEffectWidth // this will show the visual effect
        buttonDownVisualEffectLayer.borderColor = buttonHighlightCGColor
        if self.widgetType == WidgetTypeEnum.button {
            self.backgroundColor = buttonHighlightColor
        }
        if vibrationOn {
            vibrationGenerator.prepare()
            vibrationGenerator.impactOccurred()
            // print("vibrationInstance: \(vibrationGenerator)")
        }
        CATransaction.commit()
    }
    
    private func handlebuttonUp() {
        // touchPad widgets never route their presses through handleButtonDown — their
        // combo tokens (hardcoded OSCL3/OSCR3 for stick pads, or hybrid extras) are
        // pressed and released exclusively by the quick-double-tap path. Sending the
        // release block here made EVERY pad lift emit an unmatched UP for its token
        // (e.g. each LSPADALT lift released L3 host-side), which cut short the same
        // token held by any other widget. Visual cleanup below still runs.
        if !OnScreenWidgetView.editMode && !CommandManager.specialOverlayButtonCmds.contains(self.cmdString)
            && self.widgetType != WidgetTypeEnum.touchPad,
           let releaseStrings = self.heldDispatchStrings {
            // Release exactly the branch that went down (latched at button-down), so a
            // mid-press change in arming can't strand keys held. No fallback when
            // nothing is latched: releasing comboButtonStrings anyway emitted duplicate
            // UPs (second lift of a multi-finger press, slide-up passes) that cut short
            // the same token held by another widget.
            self.sendComboButtonsUpEvent(comboStrings: releaseStrings, intervalMs: self.heldDispatchIntervalMs)
            self.deactivateMotion()
            // Release the mirrored legacy-button highlight (visual only; see handleButtonDown).
            if self.widgetType == WidgetTypeEnum.button {
                for token in releaseStrings {
                    self.onScreenControls.mirrorLegacyButtonHighlight(forString: token, pressed: false)
                }
            }
            self.heldDispatchStrings = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // self.layer.borderWidth = 1
        buttonDownVisualEffectLayer.borderWidth = 0
        if self.widgetType == WidgetTypeEnum.button {
            self.tweakAlpha()
        }
        buttonDownVisualEffectLayer.borderColor = defaultBorderColor
        CATransaction.commit()
    }
    
    private func setupLrudDirectionIndicatorlayers() {
        self.layer.superlayer?.insertSublayer(leftIndicator, below: self.layer);
        self.layer.superlayer?.insertSublayer(rightIndicator, below: self.layer);
        self.layer.superlayer?.insertSublayer(upIndicator, below: self.layer);
        self.layer.superlayer?.insertSublayer(downIndicator, below: self.layer);
        leftIndicator.borderColor = UIColor.clear.cgColor
        rightIndicator.borderColor = UIColor.clear.cgColor
        upIndicator.borderColor = UIColor.clear.cgColor
        downIndicator.borderColor = UIColor.clear.cgColor
        self.lrudIndicatorBall = self.createLrudBall()
    }
    
    private func setupButtonDownVisualEffectLayer() {
        self.buttonDownVisualEffectWidth = 2.5 // original 8
//        if self.shape == "round" {
//            if deNormalizedWidthFactor < 1.3 {self.buttonDownVisualEffectWidth = 15.3} // wider visual effect for osc buttons
//            else {self.buttonDownVisualEffectWidth = 9}
//        }
        
        // Set the frame to be larger than the view to expand outward
        buttonDownVisualEffectLayer.borderWidth = 0 // set this 0 to hide the visual effect first
        buttonDownVisualEffectLayer.frame = self.bounds.insetBy(dx: -self.buttonDownVisualEffectWidth, dy: -self.buttonDownVisualEffectWidth) // Adjust the inset as needed
        buttonDownVisualEffectLayer.cornerRadius = self.layer.cornerRadius + self.buttonDownVisualEffectWidth
        buttonDownVisualEffectLayer.backgroundColor = UIColor.clear.cgColor;
        buttonDownVisualEffectLayer.fillColor = UIColor.clear.cgColor;
        buttonDownVisualEffectLayer.borderColor = buttonHighlightCGColor

        // Create a path for the border
        let path = UIBezierPath(roundedRect: buttonDownVisualEffectLayer.bounds, cornerRadius: buttonDownVisualEffectLayer.cornerRadius)
        buttonDownVisualEffectLayer.path = path.cgPath

        // Add the border layer below the main view layer
        self.layer.superlayer?.insertSublayer(buttonDownVisualEffectLayer, below: self.layer)
        
        // Retrieve the current frame to account for transformations, this will update the coords for new position CGPointMake
        buttonDownVisualEffectLayer.position = CGPointMake(CGRectGetMidX(self.frame), CGRectGetMidY(self.frame))
    }
    //==========================================================================================================
    
    
    //=========================================send on screen controller stick events
    private func touchInputToStickInput(input: CGFloat) -> CGFloat{
        var target = stickMaxOffset * input / stickInputScale
        if target > stickMaxOffset {target = stickMaxOffset}
        if target < -stickMaxOffset {target = -stickMaxOffset}
        return target
    }
    
    private func touchInputToStickBallCoord(input: CGFloat) -> CGFloat {
        if input > stickInputScale {
            return stickBallMaxOffset
        }
        if input < -stickInputScale {
            return -stickBallMaxOffset
        }
        return input * (18/stickInputScale)
    }

    // Reshape the (already-clamped) stick offset radially: keep the direction,
    // remap magnitude through a power curve so tiny offsets shrink further while
    // the boundary still maps to full deflection.
    private func applyStickResponseCurve(_ adjX: inout CGFloat, _ adjY: inout CGFloat) {
        guard stickResponseExponent.isFinite, stickResponseExponent > 1.0 else { return }
        let mag = hypot(adjX, adjY)
        guard mag > 0 else { return }
        let normalized = min(mag / stickInputScale, 1.0)
        let curved = pow(normalized, stickResponseExponent)
        let scale = (curved * stickInputScale) / mag
        adjX *= scale
        adjY *= scale
    }

    private func clampVector(x: CGFloat, y: CGFloat, radius: CGFloat) -> CGPoint {
        let mag = hypot(x, y)
        guard mag > radius, mag > 0 else { return CGPoint(x: x, y: y) }
        let scale = radius / mag
        return CGPoint(x: x * scale, y: y * scale)
    }

    private func sendRightStickTouchPadEvent(inputX: CGFloat, inputY: CGFloat){
        // Flip on the source axis so the deadband / response-curve / clamp all
        // operate consistently with the post-flip sign. Flipping after the
        // post-deadband transform would invert minStickOffset's tie-at-zero
        // bias, producing -minStickOffset when the finger is exactly centered.
        var adjX = self.stickInvertHorizontal ? -inputX : inputX
        var adjY = self.stickInvertVertical ? -inputY : inputY
        if self.isRightAltStickPad { // circular clamp for ALT variant
            let mag = hypot(adjX, adjY)
            if mag > stickInputScale && mag > 0 { // clamp in source domain to keep mapping consistent
                let scale = stickInputScale / mag
                adjX *= scale
                adjY *= scale
            }
            applyStickResponseCurve(&adjX, &adjY)
        }
        var targetX = self.touchInputToStickInput(input: adjX)
        var targetY = -self.touchInputToStickInput(input: adjY)
        // vertical input must be inverted
        targetX = (targetX >= 0 ? 1.0 : -1.0) * self.minStickOffset + (self.stickMaxOffset - self.minStickOffset) * (targetX/self.stickMaxOffset)
        targetY = (targetY >= 0 ? 1.0 : -1.0) * self.minStickOffset + (self.stickMaxOffset - self.minStickOffset) * (targetY/self.stickMaxOffset)
        if self.isAimStickPad && self.isAimRelativeModeActive {
            let maxOutputMagnitude = stickMaxOffset * aimMaxOutputScale
            let outputMagnitude = hypot(targetX, targetY)
            if outputMagnitude > maxOutputMagnitude && outputMagnitude > 0 {
                let scale = maxOutputMagnitude / outputMagnitude
                targetX *= scale
                targetY *= scale
            }
        }
        self.onScreenControls.sendRightStickTouchPadEvent(targetX, targetY)
    }

    private var isAimRelativeModeActive: Bool {
        guard aimRelativeModeEnabled else { return false }
        let activation = CommandManager.normalizedAimRelativeActivationCommand(aimRelativeActivationButton)
        if activation == CommandManager.aimRelativeActivationOn { return true }
        if activation == CommandManager.aimRelativeActivationOff { return false }
        return self.onScreenControls.isOnlyControllerButtonPressed(forString: activation)
    }

    private func resetAimStickState(clearHostStick: Bool) {
        aimTrackpadDisplayLink?.invalidate()
        aimTrackpadDisplayLink = nil
        aimTrackpadImpulse = .zero
        aimTrackpadResidualDelta = .zero
        aimTrackpadPendingDelta = .zero
        aimTrackpadLastFrameTimestamp = 0
        aimTrackpadLastOutput = .zero
        aimTrackpadHasOutput = false
        aimTrackpadLastInjectTimestamp = 0
        aimTouchSawMovement = false
        aimTouchBeganWhileCoasting = false
        aimRelativeModeWasActive = false
        aimAnchorLocation = .zero
        aimHasAnchor = false
        aimLastMoveTimestamp = 0
        if clearHostStick {
            self.onScreenControls.clearRightStickTouchPadFlag()
        }
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0.0), 1.0)
        return t * t * (3.0 - 2.0 * t)
    }

    private func applyTrackpadDeadzoneCompensation(targetX: inout CGFloat, targetY: inout CGFloat) {
        guard aimTrackpadDeadzoneCompensation > 0 else { return }
        let mag = hypot(targetX, targetY)
        guard mag > 0 else { return }
        // Steam-style anti-deadzone: linearly rescale magnitude [0, max] onto
        // [minOffset, max]. With minOffset set to the game's stick deadzone the
        // in-game response becomes linear from zero. The old hard floor
        // (max(mag, floor)) flattened every micro-aim magnitude below the
        // floor to the same output, which is exactly the "tiny move
        // dead/jumpy" symptom in AIM_PAD_DESIGN_PROPOSAL.md.
        let minOffset = stickMaxOffset * aimTrackpadDeadzoneCompensation
        let target = minOffset + (stickMaxOffset - minOffset) * min(mag / stickMaxOffset, 1.0)
        let scale = target / mag
        targetX *= scale
        targetY *= scale
    }

    // Strokes within the snap cone of an axis get their cross-axis component
    // compressed toward zero, so a thumb's natural arc reads as a straight
    // line. smoothStep keeps the compression continuous in stroke angle:
    // dead-on-axis → fully snapped, cone edge → untouched, no pop when an
    // intentional diagonal crosses the boundary.
    private func applyAimAxisSnap(to delta: inout CGPoint) {
        guard aimTrackpadAxisSnapDegrees > 0 else { return }
        let ax = abs(delta.x)
        let ay = abs(delta.y)
        guard ax > 0 || ay > 0 else { return }
        let cone = tan(aimTrackpadAxisSnapDegrees * .pi / 180.0)
        if ay < ax * cone {
            delta.y *= smoothStep(ay / (ax * cone))
        } else if ax < ay * cone {
            delta.x *= smoothStep(ax / (ay * cone))
        }
    }

    private func startAimTrackpadDisplayLink() {
        guard aimTrackpadDisplayLink == nil else { return }
        aimTrackpadLastFrameTimestamp = CACurrentMediaTime()
        if aimTrackpadLastInjectTimestamp == 0 {
            aimTrackpadLastInjectTimestamp = aimTrackpadLastFrameTimestamp
        }
        let displayLink = CADisplayLink(target: self, selector: #selector(handleAimTrackpadDisplayLink(_:)))
        displayLink.add(to: .main, forMode: .common)
        aimTrackpadDisplayLink = displayLink
    }

    private func stopAimTrackpadDisplayLink(clearHostStick: Bool) {
        aimTrackpadDisplayLink?.invalidate()
        aimTrackpadDisplayLink = nil
        aimTrackpadLastFrameTimestamp = 0
        aimTrackpadLastOutput = .zero
        aimTrackpadHasOutput = false
        aimTrackpadPendingDelta = .zero
        aimTrackpadLastInjectTimestamp = 0
        aimRelativeModeWasActive = false
        self.offSetX = 0
        self.offSetY = 0
        if clearHostStick {
            self.onScreenControls.clearRightStickTouchPadFlag()
        }
    }

    private func sendRightAimTrackpadSource(_ source: CGPoint, dt: CGFloat) {
        let visualOffset = clampVector(x: source.x, y: source.y, radius: stickInputScale)
        self.offSetX = visualOffset.x
        self.offSetY = visualOffset.y

        let clampedSource = clampVector(x: source.x, y: source.y, radius: stickInputScale)
        let adjX = self.stickInvertHorizontal ? -clampedSource.x : clampedSource.x
        let adjY = self.stickInvertVertical ? -clampedSource.y : clampedSource.y

        var targetX = self.touchInputToStickInput(input: adjX)
        var targetY = -self.touchInputToStickInput(input: adjY)
        applyTrackpadDeadzoneCompensation(targetX: &targetX, targetY: &targetY)

        let maxOutputMagnitude = stickMaxOffset * aimMaxOutputScale
        let outputMagnitude = hypot(targetX, targetY)
        if outputMagnitude > maxOutputMagnitude && outputMagnitude > 0 {
            let scale = maxOutputMagnitude / outputMagnitude
            targetX *= scale
            targetY *= scale
        }

        let reversed = aimTrackpadHasOutput && (targetX * aimTrackpadLastOutput.x + targetY * aimTrackpadLastOutput.y) < 0
        let tau = reversed ? aimTrackpadOutputReverseTau : aimTrackpadOutputSmoothingTau
        let alpha = 1.0 - exp(-dt / tau)
        if aimTrackpadHasOutput {
            targetX = aimTrackpadLastOutput.x + (targetX - aimTrackpadLastOutput.x) * alpha
            targetY = aimTrackpadLastOutput.y + (targetY - aimTrackpadLastOutput.y) * alpha
        } else {
            aimTrackpadHasOutput = true
        }
        aimTrackpadLastOutput = CGPoint(x: targetX, y: targetY)
        self.onScreenControls.sendRightStickTouchPadEvent(targetX, targetY)
    }

    @objc private func handleAimTrackpadDisplayLink(_ displayLink: CADisplayLink) {
        // Deliberately no `pressed` check: after lift-off the remaining impulse
        // keeps draining (swipe coast). A fast swipe parks most of its travel in
        // the pool — clearing it on lift-off used to throw away ~75% of a quick
        // 200pt flick, which is why fast aim turns felt short.
        guard self.isAimStickPad, self.isAimRelativeModeActive else {
            aimTrackpadImpulse = .zero
            stopAimTrackpadDisplayLink(clearHostStick: true)
            return
        }

        let now = displayLink.timestamp
        let elapsed = aimTrackpadLastFrameTimestamp > 0 ? now - aimTrackpadLastFrameTimestamp : displayLink.duration
        aimTrackpadLastFrameTimestamp = now
        let dt = min(max(CGFloat(elapsed), 1.0 / 240.0), 1.0 / 30.0)

        injectPendingAimDelta(timestamp: now)

        // Finger resting on the pad without effective movement: collapse the
        // pool quickly so the crosshair settles under the finger instead of
        // drifting through the stored budget (press-to-stop). Skipped after
        // lift-off so a swipe's remaining budget still coasts to completion.
        if self.touchBegan, now - aimTrackpadLastInjectTimestamp > aimTrackpadStillHoldDelay {
            let decay = exp(-dt / aimTrackpadStillDecayTau)
            aimTrackpadImpulse.x *= decay
            aimTrackpadImpulse.y *= decay
        }

        let impulseMagnitude = hypot(aimTrackpadImpulse.x, aimTrackpadImpulse.y)
        let responseTime = aimTrackpadResponseDuration
        let stopThreshold = stickInputScale * responseTime * aimTrackpadStopThreshold
        guard impulseMagnitude > stopThreshold else {
            aimTrackpadImpulse = .zero
            stopAimTrackpadDisplayLink(clearHostStick: true)
            return
        }

        let rawSource = CGPoint(
            x: aimTrackpadImpulse.x / responseTime,
            y: aimTrackpadImpulse.y / responseTime
        )
        let source = clampVector(x: rawSource.x, y: rawSource.y, radius: stickInputScale)
        sendRightAimTrackpadSource(source, dt: dt)

        let drain = CGPoint(x: source.x * dt, y: source.y * dt)
        if hypot(drain.x, drain.y) >= impulseMagnitude {
            aimTrackpadImpulse = .zero
        } else {
            aimTrackpadImpulse.x -= drain.x
            aimTrackpadImpulse.y -= drain.y
        }
    }

    // Runs on the display-link clock. Consumes the touch deltas accumulated since
    // the previous frame and turns them into impulse budget.
    private func injectPendingAimDelta(timestamp: CFTimeInterval) {
        let pending = aimTrackpadPendingDelta
        aimTrackpadPendingDelta = .zero
        aimTrackpadResidualDelta.x += pending.x
        aimTrackpadResidualDelta.y += pending.y

        let deltaMagnitude = hypot(aimTrackpadResidualDelta.x, aimTrackpadResidualDelta.y)
        guard deltaMagnitude >= aimTrackpadNoiseDeadzone else {
            return
        }

        var activeDelta = aimTrackpadResidualDelta
        aimTrackpadResidualDelta = .zero
        applyAimAxisSnap(to: &activeDelta)

        let newImpulse = CGPoint(
            x: activeDelta.x * aimTrackpadGain * aimTrackpadReferenceResponseTime,
            y: activeDelta.y * aimTrackpadGain * aimTrackpadReferenceResponseTime
        )

        let pendingMagnitude = hypot(aimTrackpadImpulse.x, aimTrackpadImpulse.y)
        let newMagnitude = hypot(newImpulse.x, newImpulse.y)
        if pendingMagnitude > 0, newMagnitude > 0 {
            let alignment = (aimTrackpadImpulse.x * newImpulse.x + aimTrackpadImpulse.y * newImpulse.y) / (pendingMagnitude * newMagnitude)
            if alignment < aimTrackpadReverseAlignment {
                // Genuine reversal: drop the old budget so the turn-back is
                // immediate. Smoothing state stays intact — the reverse tau in
                // sendRightAimTrackpadSource handles the transition without the
                // old one-frame output snap.
                aimTrackpadImpulse = .zero
            }
        }

        aimTrackpadImpulse.x += newImpulse.x
        aimTrackpadImpulse.y += newImpulse.y

        let maxImpulse = stickInputScale * aimTrackpadMaxImpulseTime
        let impulseMagnitude = hypot(aimTrackpadImpulse.x, aimTrackpadImpulse.y)
        if impulseMagnitude > maxImpulse && impulseMagnitude > 0 {
            let scale = maxImpulse / impulseMagnitude
            aimTrackpadImpulse.x *= scale
            aimTrackpadImpulse.y *= scale
        }

        aimTrackpadLastInjectTimestamp = timestamp
    }

    private func sendRightAimStickRelativeEvent(deltaX: CGFloat, deltaY: CGFloat, elapsed _: CFTimeInterval) {
        aimTrackpadPendingDelta.x += deltaX
        aimTrackpadPendingDelta.y += deltaY
        startAimTrackpadDisplayLink()
    }

    private func handleRightAimStickMove(touch: UITouch) {
        let now = CACurrentMediaTime()
        let currentLocation = touch.location(in: self)
        let elapsed = aimLastMoveTimestamp > 0 ? now - aimLastMoveTimestamp : 1.0 / 60.0
        recordAltStickDoubleTapMovement(to: currentLocation)
        if !aimTouchSawMovement {
            let travel = hypot(currentLocation.x - touchBeganLocation.x,
                               currentLocation.y - touchBeganLocation.y)
            if travel > ALT_STICK_DOUBLE_TAP_STATIONARY_SLOP {
                aimTouchSawMovement = true
            }
        }
        self.deltaX = currentLocation.x - self.latestTouchLocation.x
        self.deltaY = currentLocation.y - self.latestTouchLocation.y
        self.latestTouchLocation = currentLocation
        if !aimHasAnchor {
            aimAnchorLocation = touchBeganLocation
            aimHasAnchor = true
        }
        aimLastMoveTimestamp = now

        let relativeAimActive = self.isAimRelativeModeActive
        let previousRelativeAimActive = aimRelativeModeWasActive
        let scaledDeltaX = self.deltaX * (relativeAimActive ? self.aimSensitivityFactorX : self.sensitivityFactorX)
        let scaledDeltaY = self.deltaY * (relativeAimActive ? self.aimSensitivityFactorY : self.sensitivityFactorY)
        if previousRelativeAimActive && !relativeAimActive {
            aimTrackpadImpulse = .zero
            aimTrackpadResidualDelta = .zero
            aimTrackpadPendingDelta = .zero
            stopAimTrackpadDisplayLink(clearHostStick: false)
            aimAnchorLocation = currentLocation
            touchBeganLocation = currentLocation
            if let superLayer = self.layer.superlayer {
                touchBeganPosInSuperLayer = superLayer.convert(currentLocation, from: self.layer)
            }
            if widgetType == WidgetTypeEnum.touchPad {
                showStickIndicator()
            }
        } else if !previousRelativeAimActive && relativeAimActive {
            aimTrackpadResidualDelta = .zero
            aimTrackpadPendingDelta = .zero
            aimTrackpadLastOutput = .zero
            aimTrackpadHasOutput = false
            hideStickIndicatorImmediately()
        }
        aimRelativeModeWasActive = relativeAimActive

        if relativeAimActive {
            self.sendRightAimStickRelativeEvent(
                deltaX: scaledDeltaX,
                deltaY: scaledDeltaY,
                elapsed: elapsed
            )
            aimAnchorLocation = currentLocation
        } else {
            self.offSetX = currentLocation.x - aimAnchorLocation.x
            self.offSetY = currentLocation.y - aimAnchorLocation.y
            self.sendRightStickTouchPadEvent(
                inputX: self.offSetX * self.sensitivityFactorX,
                inputY: self.offSetY * self.sensitivityFactorY
            )
        }
    }

    private func sendLeftStickTouchPadEvent(inputX: CGFloat, inputY: CGFloat){
        var adjX = self.stickInvertHorizontal ? -inputX : inputX
        var adjY = self.stickInvertVertical ? -inputY : inputY
        if self.touchPadString == "LSPADALT" { // circular clamp for ALT variant
            let mag = hypot(adjX, adjY)
            if mag > stickInputScale && mag > 0 {
                let scale = stickInputScale / mag
                adjX *= scale
                adjY *= scale
            }
            applyStickResponseCurve(&adjX, &adjY)
        }
        var targetX = self.touchInputToStickInput(input: adjX)
        var targetY = -self.touchInputToStickInput(input: adjY)
        targetX = (targetX >= 0 ? 1.0 : -1.0) * self.minStickOffset + (self.stickMaxOffset - self.minStickOffset) * (targetX/self.stickMaxOffset)
        targetY = (targetY >= 0 ? 1.0 : -1.0) * self.minStickOffset + (self.stickMaxOffset - self.minStickOffset) * (targetY/self.stickMaxOffset)
        self.onScreenControls.sendLeftStickTouchPadEvent(targetX, targetY)
    }
    //==========================================================================================================
    
    private func sendOscButtonDownEvent(oscString: String){
        let buttonFlag = CommandManager.oscButtonMappings[oscString]
        if buttonFlag != 0 {self.onScreenControls.pressDownControllerButton(buttonFlag!)}
        else {switch oscString {
        case "OSCL2", "L2", "LT":
            self.onScreenControls.updateLeftTrigger(0xFF)
        case "OSCR2", "R2", "RT":
            self.onScreenControls.updateRightTrigger(0xFF)
        default:break
        }}
    }

    private func sendOscButtonUpEvent(oscString: String){
        let buttonFlag = CommandManager.oscButtonMappings[oscString]
        if buttonFlag != 0 {self.onScreenControls.releaseControllerButton(buttonFlag!)}
        else {switch oscString {
        case "OSCL2", "L2", "LT":
            self.onScreenControls.updateLeftTrigger(0x00)
        case "OSCR2", "R2", "RT":
            self.onScreenControls.updateRightTrigger(0x00)
        default:break
        }}
    }
    
//==============================================================================
    // Trailing tap (a '*' token in the last combo slot, with no following press to
    // ride) is held this long before release so the host still sees a distinct press.
    private static let trailingTapHoldMs: UInt32 = 50

    // Parse a combo string ("OSCB*-OSCR2-50MS") into ordered tokens, parallel tap flags
    // ('*' suffix = press-then-auto-release), and the trailing inter-key interval.
    private static func parseComboString(_ raw: String) -> (tokens: [String], taps: [Bool], intervalMs: UInt32) {
        var parts = raw.uppercased().split(separator: "-").map(String.init)
        var intervalMs: UInt32 = 0
        if var last = parts.last {
            // Tolerate a stray '*' on the interval token (e.g. "50MS*"): the marker is
            // meaningless there, but the editor validation already strips it, so match that
            // here instead of letting "50MS" leak in as a bogus button token at 0ms.
            if last.hasSuffix("*") { last = String(last.dropLast()) }
            if last.hasSuffix("MS"), let value = UInt32(last.dropLast(2)) {
                intervalMs = value
                parts.removeLast()
            }
        }
        var tokens: [String] = []
        var taps: [Bool] = []
        for part in parts {
            if part.hasSuffix("*") {
                taps.append(true)
                tokens.append(String(part.dropLast()))
            } else {
                taps.append(false)
                tokens.append(part)
            }
        }
        return (tokens, taps, intervalMs)
    }

    // Strips a single trailing '*' tap marker from each '-'-separated token, leaving the
    // rest intact (matches parseComboString) — used to validate against the known-token
    // grammar, which doesn't know about '*'.
    private static func stripTrailingTapMarkers(_ combo: String) -> String {
        return combo
            .split(separator: "-", omittingEmptySubsequences: false)
            .map { part -> String in
                var token = String(part)
                if token.hasSuffix("*") { token.removeLast() }
                return token
            }
            .joined(separator: "-")
    }

    // parseComboString + pulls the GYRO/GYROPAUSE motion token out of the press sequence.
    // Motion is a hold-tied mode (activated on button-down, released on button-up), so it
    // must not flow through the press/release combo path. Returns the remaining button
    // tokens (with aligned tap flags), the interval, and the motion token ("" if none).
    private static func parseButtonOutput(_ raw: String) -> (tokens: [String], taps: [Bool], intervalMs: UInt32, motion: String) {
        let parsed = parseComboString(raw)
        var buttonTokens: [String] = []
        var buttonTaps: [Bool] = []
        var motion = ""
        for (index, token) in parsed.tokens.enumerated() {
            if CommandManager.motionControlButtonCmds.contains(token) {
                if motion.isEmpty { motion = token }
            } else {
                buttonTokens.append(token)
                buttonTaps.append(index < parsed.taps.count ? parsed.taps[index] : false)
            }
        }
        return (buttonTokens, buttonTaps, parsed.intervalMs, motion)
    }

    // True when this is a conditional widget AND every arm token is in the last activation.
    private func conditionIsArmed() -> Bool {
        guard isConditional, !conditionArmTokens.isEmpty else { return false }
        return CommandManager.shared.lastActivationContainsAll(conditionArmTokens)
    }

    // The (tokens, tap flags, interval) to fire for this press: the armed output when a
    // conditional widget is armed, otherwise the base combo (also the non-conditional path).
    private func resolveDispatch() -> (strings: [String], taps: [Bool], intervalMs: UInt32, motion: String) {
        if isConditional && conditionIsArmed() {
            return (conditionArmedStrings, conditionArmedTapFlags, conditionArmedIntervalMs, conditionArmedMotionString)
        }
        if isConditional {
            return (comboButtonStrings, comboButtonTapFlags, comboKeyTimeIntervalMs, conditionBaseMotionString)
        }
        return (comboButtonStrings, comboButtonTapFlags, comboKeyTimeIntervalMs, motionControlButtonString)
    }

    private func pressComboToken(_ token: String) {
        if CommandManager.oscButtonMappings.keys.contains(token) {
            self.sendOscButtonDownEvent(oscString: token)
        }
        if CommandManager.keyboardButtonMappings.keys.contains(token) {
            LiSendKeyboardEvent(CommandManager.keyboardButtonMappings[token]!, Int8(KEY_ACTION_DOWN), 0)
        }
        if CommandManager.mouseButtonMappings.keys.contains(token) {
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), Int32(CommandManager.mouseButtonMappings[token]!))
        }
    }

    private func releaseComboToken(_ token: String) {
        if CommandManager.oscButtonMappings.keys.contains(token) {
            self.sendOscButtonUpEvent(oscString: token)
        }
        if CommandManager.keyboardButtonMappings.keys.contains(token) {
            LiSendKeyboardEvent(CommandManager.keyboardButtonMappings[token]!, Int8(KEY_ACTION_UP), 0)
        }
        if CommandManager.mouseButtonMappings.keys.contains(token) {
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), Int32(CommandManager.mouseButtonMappings[token]!))
        }
    }

    // tapFlags empty (or shorter than comboStrings) ⇒ those tokens are held to release =
    // exactly the legacy all-hold behavior. intervalMs nil ⇒ use this widget's own interval.
    private func sendComboButtonsDownEvent(comboStrings: [String], tapFlags: [Bool] = [], intervalMs: UInt32? = nil) {
        let gap = intervalMs ?? self.comboKeyTimeIntervalMs
        comboSendQueue.async {
            var pendingTapReleaseIndex: Int? = nil
            for i in 0..<comboStrings.count {
                if i > 0 {
                    usleep(gap * 1000) // delay xxx ms between consecutive presses
                }
                // Let a previous tap key go right as the next one goes down, so it reads
                // as a quick tap (held ~one inter-key interval) rather than a hold.
                if let releaseIndex = pendingTapReleaseIndex {
                    self.releaseComboToken(comboStrings[releaseIndex])
                    pendingTapReleaseIndex = nil
                }
                self.pressComboToken(comboStrings[i])
                if i < tapFlags.count && tapFlags[i] {
                    pendingTapReleaseIndex = i
                }
            }
            if let releaseIndex = pendingTapReleaseIndex {
                usleep(OnScreenWidgetView.trailingTapHoldMs * 1000)
                self.releaseComboToken(comboStrings[releaseIndex])
            }
        }
    }

    // Releases every token (tap tokens were already let go during the down sequence, so
    // releasing them again is a harmless no-op) — identical to the legacy all-release path.
    private func sendComboButtonsUpEvent(comboStrings: [String], intervalMs: UInt32? = nil) {
        let gap = intervalMs ?? self.comboKeyTimeIntervalMs
        comboSendQueue.async {
            for i in 0..<comboStrings.count {
                self.releaseComboToken(comboStrings[i])
                if i != comboStrings.count - 1 {
                    usleep(gap * 1000) // delay xxx ms
                }
            }
        }
    }
    
//==============================================================================
    // Touch event handling
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Pencil passthrough runs before every other gate (including gesture
        // suppression): pencil input always belongs to the stream, never the widget.
        var touches = extractPencilPassthroughTouches(touches, with: event, phase: .began)
        if touches.isEmpty { return }
        if OnScreenWidgetView.gesturesSuppressed {
            OnScreenWidgetView.logSuppressedTouchDrop()
            super.touchesBegan(touches, with: event)
            return
        }
        if widgetType == WidgetTypeEnum.fullscreenTrigger {
            super.touchesBegan(touches, with: event)
            if OnScreenWidgetView.editMode {
                self.pressed = true
                if let touch = touches.first, let parent = self.superview {
                    // moveByTouch reads latestTouchLocation; seed it so the first drag delta is sane.
                    self.latestTouchLocation = touch.location(in: parent)
                    self.touchBeganLocation = self.latestTouchLocation
                }
                NotificationCenter.default.post(name: Notification.Name("OnScreenWidgetViewSelected"), object: self)
            }
            return
        }
        if usesPrimaryTouchTracking && !OnScreenWidgetView.editMode {
            if let primary = primaryPadTouchId,
               event?.allTouches?.contains(where: {
                   ObjectIdentifier($0) == primary && $0.phase != .ended && $0.phase != .cancelled
               }) == true {
                // Already tracking a live grip — extra fingers are ignored, but a
                // second finger still disqualifies a pending ALT stick-click.
                if isAltStickPad {
                    altStickTouchHadMultipleTouches = true
                    pendingDoubleTapComboWork?.cancel()
                    pendingDoubleTapComboWork = nil
                }
                super.touchesBegan(touches, with: event)
                return
            }
            // No live primary (or a stale id whose touch already left the event
            // stream) — adopt this touch and drop any sibling begans in the set.
            if let adopted = touches.first {
                primaryPadTouchId = ObjectIdentifier(adopted)
                if touches.count > 1 { touches = [adopted] }
            }
        }
        self.touchBegan = true
        self.directionPadTouchBegan = true
        self.firstTouchMoved = false
        if self.isAltStickPad {
            self.altStickTouchMovedBeyondTapSlop = false
            self.altStickTouchHadMultipleTouches = false
        }
        if self.isAimStickPad {
            if self.isAimRelativeModeActive, aimTrackpadDisplayLink != nil {
                // Touch-down while the previous swipe's budget is still coasting
                // (rapid repeated swipes): keep the pool and the output filter so
                // the strokes chain seamlessly. Only per-touch state resets.
                aimTouchBeganWhileCoasting = true
                aimTouchSawMovement = false
                aimTrackpadResidualDelta = .zero
                aimTrackpadPendingDelta = .zero
                aimHasAnchor = false
                aimRelativeModeWasActive = true
                // Grace period: landing the finger must not count as "holding
                // still" yet, or the still-decay would eat the coasting budget
                // before the follow-up stroke's first move event arrives.
                aimTrackpadLastInjectTimestamp = CACurrentMediaTime()
            } else {
                self.resetAimStickState(clearHostStick: true)
            }
            self.aimLastMoveTimestamp = CACurrentMediaTime()
        }
        super.touchesBegan(touches, with: event)
        // Buttons: multi-finger drumming. touchPads: MUST be multi-touch too — with
        // it off, UIKit silently drops a new touch that overlaps the previous one
        // (fast re-grips) and never delivers it, leaving the pad dead for that whole
        // grip. Stick/direction pads track one primary touch and ignore the rest
        // (usesPrimaryTouchTracking); MOUSEPAD/DS4TOUCH regain their designed
        // multi-finger behavior (two-finger right-click / multi-pointer).
        // (Edit mode keeps pads single-touch: primary filtering is runtime-only, and
        // a second delivered finger would corrupt moveByTouch's drag deltas there.)
        self.isMultipleTouchEnabled = self.widgetType == WidgetTypeEnum.button
            || (self.widgetType == WidgetTypeEnum.touchPad && !OnScreenWidgetView.editMode)

        if !OnScreenWidgetView.editMode && self.touchPadString == "TRACKBALL" {
            stopTrackballMomentum()
        }
        
        if touches.count == 1 { // to make sure touchBegan location captured properly, don't use event.alltouches.count here
            let currentTime = CACurrentMediaTime()
            touchTapTimeInterval = currentTime - touchTapTimeStamp
            touchTapTimeStamp = currentTime
            quickDoubleTapDetected = touchTapTimeInterval < QUICK_TAP_TIME_INTERVAL
            if self.isAltStickPad {
                quickDoubleTapDetected = quickDoubleTapDetected && lastAltStickTouchWasStationaryTap
            }
            
            let touch = touches.first
            if OnScreenWidgetView.editMode {self.touchBeganLocation = touch!.location(in: superview)}
            else {self.touchBeganLocation = touch!.location(in: self)}
            self.latestTouchLocation = touchBeganLocation
            // Cache absolute position in the layer.superlayer coordinate to avoid initial offset
            if let superLayer = self.layer.superlayer {
                let pointInSelfLayer = OnScreenWidgetView.editMode ? (touch?.location(in: superview))! : (touch?.location(in: self))!
                self.touchBeganPosInSuperLayer = superLayer.convert(pointInSelfLayer, from: self.layer)
            } else {
                self.touchBeganPosInSuperLayer = CGPoint(x: CGRectGetMinX(self.frame)+self.touchBeganLocation.x,
                                                         y: CGRectGetMinY(self.frame)+self.touchBeganLocation.y)
            }
        }
                
        // Counts all valid touches within the self widgetView, excluding touches in other
        // widgetViews AND forwarded pencil-passthrough touches (their .view still points at
        // this widget even though the stream owns them — counting them would fake a 2nd finger).
        let allCapturedTouchesCount = event?.allTouches?.filter({ $0.view == self && !passthroughPencilTouches.contains($0) }).count
        if allCapturedTouchesCount == 2 {
            self.twoTouchesDetected = true
            if self.isAltStickPad {
                self.altStickTouchHadMultipleTouches = true
                // A second finger disqualifies the pending stick-click: this is
                // no longer a clean double-tap sequence.
                self.pendingDoubleTapComboWork?.cancel()
                self.pendingDoubleTapComboWork = nil
            }
        }
        
        self.pressed = true

        // When widgets are globally obscured by alpha, highlight the pressed widget
        if OnScreenWidgetView.obscuredByAlpha || self.alpha < 0.05 {
            self.restoreAlphaAfterRelease = true
            self.alpha = 1.0
        }

        if !OnScreenWidgetView.editMode {
            if self.widgetType == WidgetTypeEnum.touchPad && touches.count == 1{ // don't use event?.allTouches?.count here, it will counts all touches including the ones captured by other UIViews
                switch self.touchPadString {
                case "LSPAD", "LSPADALT":
                    if self.shouldShowRuntimeStickIndicator {
                        self.showStickIndicator()
                    }
                    self.triggerQuickDoubleTapCombo()
                    // 对于 Alt 版本，降低相关控件透明度
                    if self.touchPadString == "LSPADALT" && !OnScreenWidgetView.obscuredByAlpha {
                        self.dimControlsForAltPad()
                    }
                case "RSPAD", "RSPADALT", "RSPADALT2":
                    if self.shouldShowRuntimeStickIndicator {
                        self.showStickIndicator()
                    }
                    self.triggerQuickDoubleTapCombo()
                    // 对于 Alt 版本，降低相关控件透明度
                    if self.isRightAltStickPad && !OnScreenWidgetView.obscuredByAlpha {
                        self.dimControlsForAltPad()
                    }
                case "LSVPAD":
                    self.triggerQuickDoubleTapCombo()
                case "RSVPAD":
                    self.triggerQuickDoubleTapCombo()
                case "DPAD", "WASDPAD", "ARROWPAD":
                    if allCapturedTouchesCount == 1 {showLrudBall(at: touchBeganLocation)}
                    if quickDoubleTapDetected {
                        self.sendComboButtonsDownEvent(comboStrings: self.comboButtonStrings)
                        DispatchQueue.global(qos: .userInteractive).async {
                            usleep(100000)
                            self.sendComboButtonsUpEvent(comboStrings: self.comboButtonStrings)
                        }
                    }
                case "DS4TOUCH":
                    self.triggerQuickDoubleTapCombo()
                default:
                    break
                }
                
                if self.widgetType == WidgetTypeEnum.touchPad && self.touchPadString == "MOUSEPAD" && allCapturedTouchesCount == 1 && !twoTouchesDetected {
                    switch mouseButtonAction{
                    case .leftButtonDown:
                        LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), BUTTON_LEFT)
                    case .middleButtonDown:
                        LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), BUTTON_MIDDLE)
                    case .rightButtonDown:
                        LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), BUTTON_RIGHT)
                    case .hovering,.noClick:
                        break
                    default:
                        break
                    }
                }
            }
            
            if self.widgetType == WidgetTypeEnum.touchPad && self.touchPadString == "DS4TOUCH" {
                self.handleControllerTouchesDown(touches: touches)
            }
                        
            // this will also deal with button events
            // Pure GYRO / GYROPAUSE widgets have empty comboButtonStrings — without
            // the motionControlButtonString check, the press would never reach
            // handleButtonDown and the gyro would never toggle. Conditional widgets always
            // dispatch something (resolveDispatch picks base/armed), including a base that is
            // pure gyro, so let them through regardless of comboButtonStrings.
            if self.widgetType == WidgetTypeEnum.button &&
               (!self.comboButtonStrings.isEmpty || !self.motionControlButtonString.isEmpty || self.isConditional) {
                self.handleButtonDown()
                self.capturedTouches.union(touches)
                //self.handleButtonSliding(touches: touches)
            }
            
            // legacy keyboard button combo connected by "+"
            if self.cmdString.contains("+") && !self.cmdString.contains("-"){
                let keyboardCmdStrings = CommandManager.shared.extractKeyStringsFromComboCommand(from: self.cmdString)!
                CommandManager.shared.sendKeyComboCommand(keyboardCmdStrings: keyboardCmdStrings) // send multi-key command
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { // reset shadow color immediately 50ms later
                    self.handlebuttonUp()
                }
            }
        }
        // here is in edit mode:
        else{
            self.handleButtonDown()
            NotificationCenter.default.post(name: Notification.Name("OnScreenWidgetViewSelected"),object: self) // inform layout tool controller to fetch button size factors. self will be passed as the object of the notification
        }
    }
    
    private func moveByTouch(touch: UITouch){
        let currentLocation: CGPoint
        if OnScreenWidgetView.editMode {currentLocation = touch.location(in: superview)}
        else {currentLocation = touch.location(in: self)}
                
        let offsetX = currentLocation.x - latestTouchLocation.x;
        let offsetY = currentLocation.y - latestTouchLocation.y;
        
        let outOfBoundsX = center.x+offsetX >= (self.superview?.bounds.width)! || center.x+offsetX < 0
        let outOfBoundsY = center.y+offsetY >= (self.superview?.bounds.height)! || center.y+offsetY < 0

        center = CGPoint(x: outOfBoundsX ? center.x : center.x+offsetX, y: outOfBoundsY ? center.y : center.y+offsetY)
        
        latestTouchLocation = currentLocation
        // center = currentLocation;
        //NSLog("x coord: %f, y coord: %f", self.frame.origin.x, self.frame.origin.y)
        if OnScreenWidgetView.editMode {
            guidelineDelegate?.updateGuidelinesForOnScreenWidget(self)
        }
    }
    
    private func handleControllerTouchesDown(touches: Set<UITouch>) {
        for touch in touches{
            let availablePointerIds = pointerIdPool.subtracting(activePointerIds)
            if let pointerId = availablePointerIds.first {
                pointerIdDict[ObjectIdentifier(touch)] = pointerId
                let coordX = touch.location(in: self).x/self.bounds.width
                let coordY = touch.location(in: self).y/self.bounds.height
                LiSendControllerTouchEvent(0, UInt8(LI_TOUCH_EVENT_DOWN), pointerId, Float(coordX), Float(coordY), 1)
                activePointerIds.insert(pointerId)
            }
        }
    }
    
    private func handleControllerTouchesMove(touches: Set<UITouch>) {
        for touch in touches{
            if let pointerId = pointerIdDict[ObjectIdentifier(touch)] {
                let coordX = touch.location(in: self).x/self.bounds.width
                let coordY = touch.location(in: self).y/self.bounds.height
                LiSendControllerTouchEvent(0, UInt8(LI_TOUCH_EVENT_MOVE), pointerId, Float(coordX), Float(coordY), 1)
            }
        }
    }

    private func handleControllerTouchesUp(touches: Set<UITouch>) {
        for touch in touches{
            if let pointerId = pointerIdDict[ObjectIdentifier(touch)] {
                let coordX = touch.location(in: self).x/self.bounds.width
                let coordY = touch.location(in: self).y/self.bounds.height
                LiSendControllerTouchEvent(0, UInt8(LI_TOUCH_EVENT_UP), pointerId, Float(coordX), Float(coordY), 1)
                activePointerIds.remove(pointerId)
                pointerIdDict.removeValue(forKey: ObjectIdentifier(touch))
            }
        }
    }

    
    private func handleButtonSlidingUp(touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            for subview in self.superview?.subviews ?? [] {
                if let widget = subview as? OnScreenWidgetView{
                    if !widget.capturedTouches.contains(touch) || widget.slideMode == ButtonSlideMode.disabled.rawValue {continue}
                    // Drop the capture record with the release — UIKit recycles UITouch
                    // objects, and a stale entry makes the recycled touch look already
                    // captured (slide-in stops pressing) and mis-fires slide-out UPs.
                    widget.capturedTouches.remove(touch)
                    // Only release when NO other finger still holds the target — either
                    // another captured (slid-in / direct) touch, or a live direct touch
                    // in the event. Without this, lifting a finger that merely slid
                    // across silences a button another finger is still pressing.
                    let stillHeld = widget.capturedTouches.count > 0
                        || event?.allTouches?.contains(where: { other in
                            other.view == widget
                                && other !== touch
                                && (other.phase == .began || other.phase == .moved || other.phase == .stationary)
                        }) == true
                    if !stillHeld {
                        widget.handlebuttonUp()
                    }
                }
            }
        }
    }

    private func handleButtonSliding(touches: Set<UITouch>) {
        for touch in touches {
            let locationInSuperView = touch.location(in: self.superview)
            for subview in self.superview?.subviews ?? [] {
                if let widget = subview as? OnScreenWidgetView{
                    if widget.widgetType != WidgetTypeEnum.button {continue}
                    let pointInSubview = widget.convert(locationInSuperView, from: self.superview)
                    if widget.bounds.contains(pointInSubview){
                        if widget.capturedTouches.contains(touch) || widget.slideMode == ButtonSlideMode.disabled.rawValue {continue}
                        widget.capturedTouches.add(touch)
                        widget.handleButtonDown()
                        // print("UIButton: \(widget.buttonLabel) in, \(widget.touchPadString), \(CACurrentMediaTime())")
                    }
                    else{
                        if !widget.capturedTouches.contains(touch) || widget.slideMode == ButtonSlideMode.disabled.rawValue {continue}
                        // print("UIButton: \(widget.buttonLabel) out test, \(widget.touchPadString), \(CACurrentMediaTime())")
                        if(widget.slideMode == ButtonSlideMode.toggle.rawValue){
                            widget.capturedTouches.remove(touch)
                            widget.handlebuttonUp()
                        }
                        if(widget.slideMode == ButtonSlideMode.slideAndHold.rawValue){
                            // do nothing here
                        }
                    }
                }
            }
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var touches = extractPencilPassthroughTouches(touches, with: event, phase: .moved)
        if touches.isEmpty { return }
        if OnScreenWidgetView.gesturesSuppressed {
            super.touchesMoved(touches, with: event)
            return
        }
        if widgetType == WidgetTypeEnum.fullscreenTrigger {
            super.touchesMoved(touches, with: event)
            // Allow drag in edit mode so the user can drop the handle on the trash button
            // (matches every other widget). The position itself isn't persisted — touchesEnded
            // either deletes via overlap or animates the handle back to storedCenter.
            if OnScreenWidgetView.editMode, let touch = touches.first {
                self.moveByTouch(touch: touch)
            }
            return // still no slide / touchpad behavior in runtime
        }
        if usesPrimaryTouchTracking && !OnScreenWidgetView.editMode {
            if let primary = primaryPadTouchId {
                let filtered = touches.filter { ObjectIdentifier($0) == primary }
                if filtered.isEmpty {
                    // Only ignored extra fingers moved.
                    super.touchesMoved(touches, with: event)
                    return
                }
                touches = filtered
            } else if let touch = touches.first {
                // Moves for a grip we never saw begin (dropped began / mid-touch
                // cleanup): adopt it; the re-anchor guard below resets the anchor.
                primaryPadTouchId = ObjectIdentifier(touch)
                if touches.count > 1 { touches = [touch] }
            }
        }
        super.touchesMoved(touches, with: event)
        if !OnScreenWidgetView.editMode {

            // Re-anchor guard: a move for a touch whose touchesBegan this widget never
            // processed (dropped by a gesture-suppression window, or state cleared
            // mid-touch by an external cancel). Offset-based pads would otherwise
            // compute deflection against the PREVIOUS grip's anchor — the stick pins
            // to a wrong direction (far stale anchor) or barely moves (near stale
            // anchor) until the finger lifts. Adopt the current point as a fresh
            // anchor and let the stroke continue from zero.
            if !self.touchPadString.isEmpty && !self.touchBegan, let touch = touches.first {
                self.touchBegan = true
                self.firstTouchMoved = false
                self.touchBeganLocation = touch.location(in: self)
                self.latestTouchLocation = self.touchBeganLocation
                if let superLayer = self.layer.superlayer {
                    self.touchBeganPosInSuperLayer = superLayer.convert(self.touchBeganLocation, from: self.layer)
                }
                if self.isAimStickPad {
                    self.aimHasAnchor = false
                }
            }

            if !self.touchPadString.isEmpty{
                handleTouchPadMoveEvent(touches, with: event)
            }
            
            if !self.buttonString.isEmpty{
                if self.slideMode != ButtonSlideMode.disabled.rawValue {self.handleButtonSliding(touches: touches)}
            }
            
            if CommandManager.specialOverlayButtonCmds.contains(self.cmdString){
                if let touch = touches.first {
                    if CACurrentMediaTime() - self.touchTapTimeStamp > 0.3 { // temporarily relocate special buttons
                        self.moveByTouch(touch: touch)
                        self.handlebuttonUp()
                    }
                }
            }
        }
        
        // Move the widgetView based on touch movement in relocation mode
        if OnScreenWidgetView.editMode {
            if let touch = touches.first {
                self.moveByTouch(touch: touch)
                }
            self.stickBallLayer.removeFromSuperlayer()
            self.crossMarkLayer.removeFromSuperlayer()
        }
    }
    
    private func updateTouchLocation (touch: UITouch) {
        self.mousePointerMoved = true
        let currentTouchLocation: CGPoint = (touch.location(in: self))
        
        if !firstTouchMoved {
            // First move event
            self.latestTouchLocation = currentTouchLocation
            self.firstTouchMoved = true
        }
        
        self.deltaX = currentTouchLocation.x - self.latestTouchLocation.x
        self.deltaY = currentTouchLocation.y - self.latestTouchLocation.y
        self.offSetX = currentTouchLocation.x - self.touchBeganLocation.x
        self.offSetY = currentTouchLocation.y - self.touchBeganLocation.y
        recordAltStickDoubleTapMovement(to: currentTouchLocation)
        self.latestTouchLocation = currentTouchLocation
    }
    
    // All cases now read the UITouch and compute deltas on the calling (main) thread
    // and invoke the send directly. The old per-event hop to the CONCURRENT global
    // queue read `touch.location(in:)` off the main thread (UITouch is not
    // thread-safe), raced the shared delta/latestTouchLocation state, and — being
    // concurrent — could process move events out of order, which showed up as
    // stick/mouse jitter. The Li* send functions just enqueue into the input queue
    // (the legacy OSC path already calls them on the main thread), so the direct
    // call also removes a queue-hop of input latency.
    private func handleTouchPadMoveEvent (_ touches: Set<UITouch>, with event: UIEvent?){
        if touches.count == 1{ // don't use event.alltouches.count here, it will counts all touches
            switch self.touchPadString{
            case "MOUSEPAD":
                self.updateTouchLocation(touch: touches.first!)
                LiSendMouseMoveEvent(Int16(truncatingIfNeeded: Int(self.deltaX * 1.7 * self.sensitivityFactorX)), Int16(truncatingIfNeeded: Int(self.deltaY * 1.7 * self.sensitivityFactorY)))
            case "TRACKBALL":
                self.updateTouchLocation(touch: touches.first!)
                LiSendMouseMoveEvent(Int16(truncatingIfNeeded: Int(self.deltaX * 1.7 * self.sensitivityFactorX)), Int16(truncatingIfNeeded: Int(self.deltaY * 1.7 * self.sensitivityFactorY)))
                self.trackballVelocity = CGPoint(x: self.deltaX * 1.7 * self.sensitivityFactorX, y: self.deltaY * 1.7 * self.sensitivityFactorY)
                self.stopTrackballMomentum()
            case "LSPAD", "LSPADALT":
                self.updateTouchLocation(touch: touches.first!)
                self.sendLeftStickTouchPadEvent(inputX: self.offSetX * self.sensitivityFactorX, inputY: self.offSetY * self.sensitivityFactorY)
                if widgetType == WidgetTypeEnum.touchPad && shouldShowRuntimeStickIndicator {updateStickIndicator()}
            case "RSPAD", "RSPADALT":
                self.updateTouchLocation(touch: touches.first!)
                self.sendRightStickTouchPadEvent(inputX: self.offSetX * self.sensitivityFactorX, inputY: self.offSetY * self.sensitivityFactorY)
                if widgetType == WidgetTypeEnum.touchPad && shouldShowRuntimeStickIndicator {updateStickIndicator()}
            case "RSPADALT2":
                self.handleRightAimStickMove(touch: touches.first!)
                if widgetType == WidgetTypeEnum.touchPad && shouldShowRuntimeStickIndicator {updateStickIndicator()}
            case "LSVPAD":
                self.updateTouchLocation(touch: touches.first!)
                self.sendLeftStickTouchPadEvent(inputX: self.deltaX*1.5167*self.sensitivityFactorX, inputY: self.deltaY*1.5167*self.sensitivityFactorY)
            case "RSVPAD":
                self.updateTouchLocation(touch: touches.first!)
                self.sendRightStickTouchPadEvent(inputX: self.deltaX*1.5167*self.sensitivityFactorX, inputY: self.deltaY*1.5167*self.sensitivityFactorY)
            case "DPAD", "WASDPAD", "ARROWPAD":
                self.updateTouchLocation(touch: touches.first!)
                handleLrudTouchMove()
            default:
                break
            }
        }
        if self.widgetType == WidgetTypeEnum.touchPad && self.touchPadString == "DS4TOUCH" {
            self.handleControllerTouchesMove(touches: touches)
        }
    }

    // iOS sends touchesCancelled when a touch sequence is interrupted by the
    // system (incoming call, control center swipe, modal alert, gesture
    // recognizer claim, app→background, etc.). Without this override, UIView's
    // default behavior is to silently drop the touch — which means handleButtonDown
    // already fired (push to motion-button hold count, host received OSCR2 down,
    // etc.) but the matching handlebuttonUp never runs. Result: motion button
    // count leaks → gyro fires forever even after the user lets go, AND the
    // host-side button stays stuck → all subsequent screen taps fight the stuck
    // input. Routing to the same cleanup path the gesture-suppression observer
    // uses keeps both the local count and the host-side button state balanced.
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Forward passthrough pencil cancels to the stream; if the cancel set was
        // pencil-only, the widget never owned those touches, so skip the
        // active-input cleanup (it would wrongly release live finger touches).
        let touches = extractPencilPassthroughTouches(touches, with: event, phase: .cancelled)
        if touches.isEmpty { return }
        super.touchesCancelled(touches, with: event)
        if usesPrimaryTouchTracking && !OnScreenWidgetView.editMode, let primary = primaryPadTouchId,
           !touches.contains(where: { ObjectIdentifier($0) == primary }) {
            // Only ignored extra fingers were cancelled; the primary grip continues.
            return
        }
        cancelActiveTouchesDueToGestureSuppression()
    }

    // Same leak class as touchesCancelled: a widget can be removed from its
    // superview (OSC layout reload, clearOnScreenWidgets) while the user's
    // finger is still down on it. Without this, the matching handlebuttonUp
    // never runs and motion-button count + host R2 state leak the same way.
    // Slide-captured buttons (handleButtonSliding) leave `pressed=false` but
    // still hold capturedTouches and may have pushed motion-button state, so
    // we widen the guard to cover all "this widget owns active input" cases.
    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        guard newSuperview == nil else { return }
        // Coasting counts as active input even though the finger is already up:
        // the aim pad's post-liftoff impulse drain (CADisplayLink, retained by
        // the run loop) and the trackball momentum timer both keep SENDING
        // events after this widget is removed — the aim pad's are latched
        // right-stick values, which the host holds forever if the stream is
        // torn down right after the last (non-zero) send.
        let hasActiveInput = self.pressed
            || self.motionButtonHeld
            || self.capturedTouches.count > 0
            || self.activePointerIds.count > 0
            || aimTrackpadDisplayLink != nil
            || trackballDecelerationTimer != nil
        if hasActiveInput {
            cancelActiveTouchesDueToGestureSuppression()
        }
    }

    // Force-release every pointer the host has open for this widget's DS4TOUCH
    // surface. Used by the cancel/teardown path where we don't have specific
    // UITouch references to map.
    private func cancelAllControllerTouches() {
        for pointerId in activePointerIds {
            LiSendControllerTouchEvent(0, UInt8(LI_TOUCH_EVENT_UP), pointerId, 0, 0, 1)
        }
        activePointerIds.removeAll()
        pointerIdDict.removeAll()
    }

    @objc private func cancelActiveTouchesDueToGestureSuppression() {
        if Thread.isMainThread == false {
            DispatchQueue.main.async { self.cancelActiveTouchesDueToGestureSuppression() }
            return
        }

        if widgetType == WidgetTypeEnum.fullscreenTrigger {
            // Fullscreen trigger doesn't capture touches at runtime (hitTest returns nil) and
            // owns its own appearance via setupFullscreenTriggerView. The fall-through tweakAlpha
            // below would force a gray UIColor(white:0.2, alpha:0.32) on a full-screen view —
            // which renders as a translucent grey overlay covering the entire stream until the
            // next setupView call. Bail early; there's nothing to clean up here.
            return
        }

        // Slide-captured buttons hold capturedTouches without setting `pressed`,
        // and pure GYRO/GYROPAUSE buttons hold motion-button state. Widen the
        // cleanup guard so any of those leak paths still reaches handlebuttonUp.
        let buttonNeedsCleanup = self.pressed
            || self.motionButtonHeld
            || self.capturedTouches.count > 0
        if buttonNeedsCleanup && widgetType == WidgetTypeEnum.button {
            handlebuttonUp()
        }

        if widgetType == WidgetTypeEnum.touchPad {
            releaseQuickDoubleTapComboIfNeeded()

            switch touchPadString {
            case "LSPAD", "LSPADALT":
                onScreenControls.clearLeftStickTouchPadFlag()
                if shouldShowRuntimeStickIndicator {
                    resetStickBallPositionAndHideIndicator()
                }
            case "RSPAD", "RSPADALT", "RSPADALT2":
                onScreenControls.clearRightStickTouchPadFlag()
                if self.isAimStickPad {
                    resetAimStickState(clearHostStick: false)
                }
                if shouldShowRuntimeStickIndicator || self.isAimStickPad {
                    resetStickBallPositionAndHideIndicator()
                }
            case "LSVPAD":
                onScreenControls.clearLeftStickTouchPadFlag()
            case "RSVPAD":
                onScreenControls.clearRightStickTouchPadFlag()
            case "MOUSEPAD":
                switch mouseButtonAction {
                case .leftButtonDown:
                    LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), BUTTON_LEFT)
                case .middleButtonDown:
                    LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), BUTTON_MIDDLE)
                case .rightButtonDown:
                    LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), BUTTON_RIGHT)
                default:
                    break
                }
                stopTrackballMomentum()
                mousePointerMoved = false
            case "TRACKBALL":
                stopTrackballMomentum()
            case "DS4TOUCH":
                // touchesEnded calls handleControllerTouchesUp(touches:) which
                // needs the actual UITouches to compute final coords. The cancel
                // path doesn't have those, so force-release every open pointer
                // at (0,0) — host clears the touch state regardless of coords.
                cancelAllControllerTouches()
            case "DPAD":
                onScreenControls.releaseControllerButton(LEFT_FLAG)
                onScreenControls.releaseControllerButton(RIGHT_FLAG)
                onScreenControls.releaseControllerButton(UP_FLAG)
                onScreenControls.releaseControllerButton(DOWN_FLAG)
            case "WASDPAD":
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["W"]!, Int8(KEY_ACTION_UP), 0)
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["A"]!, Int8(KEY_ACTION_UP), 0)
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["S"]!, Int8(KEY_ACTION_UP), 0)
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["D"]!, Int8(KEY_ACTION_UP), 0)
            case "ARROWPAD":
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["LEFT_ARROW"]!, Int8(KEY_ACTION_UP), 0)
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["RIGHT_ARROW"]!, Int8(KEY_ACTION_UP), 0)
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["UP_ARROW"]!, Int8(KEY_ACTION_UP), 0)
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["DOWN_ARROW"]!, Int8(KEY_ACTION_UP), 0)
            default:
                break
            }
        }

        pressed = false
        twoTouchesDetected = false
        touchBegan = false
        primaryPadTouchId = nil
        mousePointerMoved = false
        quickDoubleTapDetected = false
        quickDoubleTapComboHeld = false
        finishAltStickDoubleTapMovementTracking(cancelled: true)
        restoreAlphaAfterRelease = false
        // Drop any captured touch references — touchesEnded clears these on the
        // happy path, but cancellation never gets there. Stale entries would
        // confuse the next slide-capture pass.
        capturedTouches.removeAllObjects()

        // In the layout editor (editMode) widgets must always stay visible. They must
        // never inherit the streaming OSC's obscure-by-alpha state — otherwise a touch
        // cancelled mid-drag (a device tilt cancels active touches) drops the widget to
        // 0.02 and it "vanishes" while editing. Guard the whole obscure condition with
        // !editMode (parenthesised: && binds tighter than ||).
        if (OnScreenWidgetView.obscuredByAlpha || superview?.alpha ?? 1.0 < 0.05) && !OnScreenWidgetView.editMode {
            self.alpha = 0.02
        } else {
            tweakAlpha()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        var touches = extractPencilPassthroughTouches(touches, with: event, phase: .ended)
        if touches.isEmpty { return }
        if OnScreenWidgetView.gesturesSuppressed {
            super.touchesEnded(touches, with: event)
            return
        }
        if widgetType == WidgetTypeEnum.fullscreenTrigger {
            super.touchesEnded(touches, with: event)
            self.pressed = false
            // The host VC's touchesEnded runs next via responder chain forwarding and will
            // remove the widget when its frame overlaps the trash button (same path as every
            // other widget). If we're still attached afterwards, animate the handle back to
            // its anchor position so the editor stays at a known, predictable spot.
            if self.superview != nil {
                let target = self.storedCenter
                UIView.animate(withDuration: 0.28,
                               delay: 0,
                               usingSpringWithDamping: 0.72,
                               initialSpringVelocity: 0.6,
                               options: [.curveEaseOut, .allowUserInteraction]) {
                    self.center = target
                }
            }
            return
        }
        if usesPrimaryTouchTracking && !OnScreenWidgetView.editMode, let primary = primaryPadTouchId {
            let filtered = touches.filter { ObjectIdentifier($0) == primary }
            if filtered.isEmpty {
                // Only ignored extra fingers lifted; the primary grip continues.
                super.touchesEnded(touches, with: event)
                return
            }
            touches = filtered
            primaryPadTouchId = nil
        }
        self.touchBegan = false
        super.touchesEnded(touches, with: event)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        // for checking stationary touch points

        if self.touchPadString != "MOUSEPAD" {quickDoubleTapDetected = false} //do not reset this flag here in mousePad mode
        
        // Counts all valid touches within the self widgetView, excluding touches in other
        // widgetViews AND forwarded pencil-passthrough touches (their .view still points at
        // this widget even though the stream owns them — counting them would fake a 2nd finger).
        let allCapturedTouchesCount = event?.allTouches?.filter({ $0.view == self && !passthroughPencilTouches.contains($0) }).count
        
        
        // deal with pure MOUSPAD first
        if !OnScreenWidgetView.editMode && self.widgetType == WidgetTypeEnum.touchPad && self.touchPadString == "MOUSEPAD" && allCapturedTouchesCount == 1 && !twoTouchesDetected {
            
                switch mouseButtonAction{
                case .leftButtonDown:
                    LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), BUTTON_LEFT)
                case .middleButtonDown:
                    LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), BUTTON_MIDDLE)
                case .rightButtonDown:
                    LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), BUTTON_RIGHT)
                case .hovering:
                    if !mousePointerMoved && !quickDoubleTapDetected {self.sendLongMouseLeftButtonClickEvent()} // deal with single tap(click)
                    if quickDoubleTapDetected { //deal with quick double tap
                        LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), BUTTON_LEFT) //must release the button anyway, because the button is likely being held down since the long click turned into a dragging event.
                        if !mousePointerMoved {self.sendShortMouseLeftButtonClickEvent()}
                        quickDoubleTapDetected = false
                    }
                    mousePointerMoved = false // reset this flag
                case .noClick:
                    break
                default:
                    break
                }
        }
        
        if !OnScreenWidgetView.editMode && self.widgetType == WidgetTypeEnum.touchPad && self.touchPadString == "TRACKBALL" && allCapturedTouchesCount == 1 && !twoTouchesDetected {
            if(mousePointerMoved){
                self.startTrackballMomentum()
                mousePointerMoved = false //reset flag
            }
            else{
                self.stopTrackballMomentum()
            }
        }
        
        if !OnScreenWidgetView.editMode && self.widgetType == WidgetTypeEnum.touchPad && self.touchPadString == "MOUSEPAD" && twoTouchesDetected && touches.count == allCapturedTouchesCount { // need to enable multi-touch first
            // touches.count == allCapturedTouchesCount means allfingers are lifting
            self.sendMouseRightButtonClickEvent()
            twoTouchesDetected = false
        }
        
        // then other types of pads or buttons with touchPad function
        if !OnScreenWidgetView.editMode && !self.touchPadString.isEmpty {
            releaseQuickDoubleTapComboIfNeeded(fireIfPending: true)
            switch self.touchPadString{
            case "LSPAD", "LSPADALT":
                self.onScreenControls.clearLeftStickTouchPadFlag()
                if widgetType == WidgetTypeEnum.touchPad && shouldShowRuntimeStickIndicator {self.resetStickBallPositionAndHideIndicator()}
                // 对于 Alt 版本，恢复相关控件透明度
                if self.touchPadString == "LSPADALT" && !OnScreenWidgetView.obscuredByAlpha {
                    self.restoreControlsOpacity()
                }
            case "RSPAD", "RSPADALT", "RSPADALT2":
                let coasting = self.isAimStickPad && self.isAimRelativeModeActive && aimTrackpadDisplayLink != nil
                // A stationary tap landing on a coasting pool means "stop" —
                // trackpad momentum semantics. Anything else with budget left
                // keeps draining after lift-off so the swipe's distance isn't lost.
                let tapToStop = aimTouchBeganWhileCoasting && !aimTouchSawMovement
                if coasting && !tapToStop {
                    aimTrackpadResidualDelta = .zero
                    aimHasAnchor = false
                    aimTouchBeganWhileCoasting = false
                    aimTouchSawMovement = false
                } else {
                    self.onScreenControls.clearRightStickTouchPadFlag()
                    if self.isAimStickPad {
                        resetAimStickState(clearHostStick: false)
                        if tapToStop {
                            // This tap was consumed as "stop the coast" — it must
                            // not double as the first half of a double-tap stick
                            // click, or stop-then-swipe within 0.2s sends R3.
                            touchTapTimeStamp = 0
                        }
                    }
                }
                if widgetType == WidgetTypeEnum.touchPad && (shouldShowRuntimeStickIndicator || self.isAimStickPad) {self.resetStickBallPositionAndHideIndicator()}
                // 对于 Alt 版本，恢复相关控件透明度
                if self.isRightAltStickPad && !OnScreenWidgetView.obscuredByAlpha {
                    self.restoreControlsOpacity()
                }
            case "LSVPAD":
                self.onScreenControls.clearLeftStickTouchPadFlag()
            case "RSVPAD":
                self.onScreenControls.clearRightStickTouchPadFlag()
            case "WASDPAD":
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["W"]!,Int8(KEY_ACTION_UP), 0)
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["A"]!,Int8(KEY_ACTION_UP), 0)
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["S"]!,Int8(KEY_ACTION_UP), 0)
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["D"]!,Int8(KEY_ACTION_UP), 0)
            case "ARROWPAD":
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["LEFT_ARROW"]!,Int8(KEY_ACTION_UP), 0)
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["RIGHT_ARROW"]!,Int8(KEY_ACTION_UP), 0)
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["UP_ARROW"]!,Int8(KEY_ACTION_UP), 0)
                LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["DOWN_ARROW"]!,Int8(KEY_ACTION_UP), 0)
            case "DPAD":
                self.onScreenControls.releaseControllerButton(LEFT_FLAG)
                self.onScreenControls.releaseControllerButton(RIGHT_FLAG)
                self.onScreenControls.releaseControllerButton(UP_FLAG)
                self.onScreenControls.releaseControllerButton(DOWN_FLAG)
            case "DS4TOUCH":
                self.handleControllerTouchesUp(touches: touches)
            default:
                break
            }
        }
        
        if CommandManager.stickTouchPads.contains(touchPadString){
            self.l3r3Indicator.borderColor = UIColor.clear.cgColor
        }
        
        if CommandManager.directionPads.contains(touchPadString){
            self.upIndicator.borderColor = UIColor.clear.cgColor
            self.downIndicator.borderColor = UIColor.clear.cgColor
            self.leftIndicator.borderColor = UIColor.clear.cgColor
            self.rightIndicator.borderColor = UIColor.clear.cgColor
            self.lrudIndicatorBall.isHidden = true
        }
                                
        if !OnScreenWidgetView.editMode {
            if !self.cmdString.contains("+") && !self.comboButtonStrings.isEmpty { // legacy "+" combos don't slide
                self.handleButtonSlidingUp(touches: touches, with: event)
            }
            // Always drop ended touches from this widget's own capture records —
            // legacy "+" buttons union their touches in touchesBegan but never
            // cleared them, so a recycled UITouch inherited stale capture state.
            self.capturedTouches.minus(touches)
        }
        
        if !OnScreenWidgetView.editMode && CommandManager.specialOverlayButtonCmds.contains(self.cmdString){
            if CACurrentMediaTime() - self.touchTapTimeStamp < 0.3 {
                switch self.cmdString {
                case "SETTINGS":
                    NotificationCenter.default.post(name: Notification.Name("SettingsOverlayButtonPressedNotification"), object:nil)
                case "CMD":
                    NotificationCenter.default.post(name: Notification.Name("CommandManagerOverlayButtonPressedNotification"), object:nil)
                default:
                    break
                }
            }
        }

        if !OnScreenWidgetView.editMode {
            finishAltStickDoubleTapMovementTracking()
        }
        
        CATransaction.commit()
        
        if OnScreenWidgetView.editMode {
            storedCenter = center // Update initial center for next movement
            if center != layoutChanges.last {
                layoutChanges.append(center)
            }

            guard let superview = superview else { return }
            
            // Deactivate existing constraints if necessary
            NSLayoutConstraint.deactivate(self.constraints)
            
            // Add new constraints based on the current center position
            translatesAutoresizingMaskIntoConstraints = true
            
            // Create new constraints
            let newLeadingConstraint = self.leadingAnchor.constraint(equalTo: superview.leadingAnchor, constant: self.frame.origin.x)
            let newTopConstraint = self.topAnchor.constraint(equalTo: superview.topAnchor, constant: self.frame.origin.y)
            
            // Activate the new location constraints
            NSLayoutConstraint.activate([newLeadingConstraint, newTopConstraint])
            
            // Trigger layout update
            superview.layoutIfNeeded()
            
            setupView(); //re-setup widgetView style
            
            if self.widgetType == WidgetTypeEnum.touchPad{
                switch self.touchPadString{
                case "LSPAD", "LSPADALT", "RSPAD", "RSPADALT", "RSPADALT2":
                    if self.shouldShowRuntimeStickIndicator {
                        self.showStickIndicator()
                        self.updateStickIndicator()
                    }
                default: break
                }
            }
        }
        
        // Buttons: release only when the LAST finger lifts. Multi-finger drumming
        // used to release the latched combo on the FIRST lift (the remaining
        // finger's hold went silent host-side) and then re-release a fallback set
        // on the second lift, cutting short the same token held elsewhere.
        if widgetType == WidgetTypeEnum.button && !OnScreenWidgetView.editMode,
           event?.allTouches?.contains(where: { other in
               other.view == self
                   && !touches.contains(other)
                   && !passthroughPencilTouches.contains(other)
                   && (other.phase == .began || other.phase == .moved || other.phase == .stationary)
           }) == true {
            // another finger still holds this button — keep it down
        } else {
            self.handlebuttonUp()
        }

        // A pad whose primary touch just lifted adopts any other finger already
        // resting on it (fast overlapping re-grip) as the new grip.
        if usesPrimaryTouchTracking && !OnScreenWidgetView.editMode && primaryPadTouchId == nil {
            adoptSuccessorPadTouch(from: event, excluding: touches)
        }
        // Restore alpha if we highlighted in touchesBegan. Never re-hide a widget while
        // editing (editMode) — see the touchesCancelled note above; lifting the finger
        // after positioning a widget would otherwise drop it to 0.02.
        if restoreAlphaAfterRelease && !OnScreenWidgetView.editMode && (OnScreenWidgetView.obscuredByAlpha || self.superview?.alpha ?? 1.0 < 0.05) {
            self.alpha = 0.02
            restoreAlphaAfterRelease = false
        }
    }
    
}
