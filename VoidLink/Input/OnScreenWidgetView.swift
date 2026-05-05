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
        DispatchQueue.main.async {
            for case let widget as OnScreenWidgetView in OnScreenWidgetView.activeInstances.allObjects {
                widget.cancelActiveTouchesDueToGestureSuppression()
            }
        }
    }

    @objc static func endGestureSuppression() {
        guard OnScreenWidgetView.gesturesSuppressed else { return }
        DispatchQueue.main.async {
            OnScreenWidgetView.gesturesSuppressed = false
        }
    }

    // receiving the OnScreenControls instance from delegate
    @objc func getOnScreenControlsInstance(_ sender: Any) {
        if let controls = sender as? OnScreenControls {
            self.onScreenControls = controls
            // Tell ControllerSupport which kind of gyro gate this widget needs.
            // Without this the gyro tick stays in legacy always-on mode.
            switch self.motionControlButtonString {
            case "GYRO":      controls.markGyroToggleButtonRegistered()
            case "GYROPAUSE": controls.markGyroPauseButtonRegistered()
            default: break
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

    @objc public var pressed: Bool
    private var restoreAlphaAfterRelease: Bool = false
    @objc public var widthFactor: CGFloat = 1.0
    @objc public var heightFactor: CGFloat = 1.0
    @objc public var slideMode: Int = 0

    @objc public var deNormalizedWidthFactor: CGFloat = 1.0
    @objc public var deNormalizedHeightFactor: CGFloat = 1.0
    
    @objc public var borderWidth: CGFloat = 0.0
    @objc public var backgroundAlpha: CGFloat = 0.5
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

    // check quick double tap:
    private var quickDoubleTapDetected: Bool
    private var touchTapTimeInterval: TimeInterval
    private var touchTapTimeStamp: TimeInterval
    private let QUICK_TAP_TIME_INTERVAL = 0.2
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
    
    // OnScreenControls instance
    private var onScreenControls: OnScreenControls
    
    // 存储原始透明度值
    private var originalOpacityValues: [String: Float] = [:]
    
    // key / button label
    private let label: UILabel
    private let outlineLabel: UILabel
    
    // first touch location within the button or pad view (self)
    @objc public var touchBeganLocation: CGPoint = .zero
    
    // for mousePad
    private var touchLockedForMoveEvent: UITouch
    private var touchBegan: Bool = false
    private var firstTouchMoved: Bool = false
    private var mousePointerMoved: Bool
    private var twoTouchesDetected: Bool
    
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
    
    //controller touch pad
    private var pointerIdPool: Set<UInt32>
    private var pointerIdDict: Dictionary<ObjectIdentifier, UInt32>
    private var activePointerIds: Set<UInt32>
    
    // whole button press down visual effect
    @objc public let buttonDownVisualEffectLayer = CAShapeLayer()
    private var buttonDownVisualEffectWidth: CGFloat

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
        
        if !self.cmdString.contains("+"){
            // 安全解包并处理 `comboKeyStrings`
            if var comboStrings = CommandManager.shared.extractSinglCmdStringsFromComboKeys(from: self.cmdString) {
                
                // extract timeInterval
                if let lastString = comboStrings.last, lastString.contains("MS") {
                    // 移除 "MS" 后的部分并转换为整数
                    let timeIntervalString = lastString.replacingOccurrences(of: "MS", with: "")
                    // 安全地将字符串转换为整数
                    if let timeInterval = UInt32(timeIntervalString) {
                        self.comboKeyTimeIntervalMs = timeInterval
                    } else {print("无法将时间字符串转换为整数")}
                    comboStrings.removeLast()
                }
                
                if CommandManager.touchPadCmds.contains(comboStrings.first ?? "") {self.widgetType = WidgetTypeEnum.touchPad}
                else {self.widgetType = WidgetTypeEnum.button}
                
                let touchPadString = Set(comboStrings).intersection(Set(CommandManager.touchPadCmds)).first ?? ""
                let motionString = Set(comboStrings).intersection(Set(CommandManager.motionControlButtonCmds)).first ?? ""
                self.comboButtonStrings = comboStrings.filter{$0 != touchPadString && $0 != motionString}
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
                case "RSPAD", "RSPADALT", "RSVPAD":
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
                if self.touchPadString == "RSPADALT" || self.touchPadString == "LSPADALT" {
                    self.stickInputScale = 55
                    self.hasResponseCurveTweak = true
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
        self.capturedTouches = NSMutableSet()
        self.pointerIdDict = [:]
        self.pointerIdPool = []
        for i in 0...10 { // iPadOS supports up to 11 finger touches
            self.pointerIdPool.insert(UInt32(i))
        }
        self.activePointerIds = []
        super.init(frame: .zero)
        OnScreenWidgetView.activeInstances.add(self)
        if self.touchPadString == "LSPADALT" || self.touchPadString == "RSPADALT" { self.stickIndicatorOffset = 0; self.hasStickIndicator = false }
        
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
        } else if self.touchPadString == "RSPADALT" {
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
        
        label.textColor = UIColor(white: 1.0, alpha: 0.64)
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
        return super.hitTest(point, with: event)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === fullscreenDoubleTapGesture else { return true }
        guard let superview = self.superview else { return true }
        let locationInSuper = touch.location(in: superview)

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
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.clear,
            .strokeColor: UIColor(white: 0.0, alpha: 0.2),
            .strokeWidth: strokeWidthPercent
        ]
        outlineLabel.attributedText = NSAttributedString(string: text, attributes: attributes)
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
        if self.touchPadString == "LSPADALT" || self.touchPadString == "RSPADALT" {
            self.stickBallLayer.isHidden = true
        } else {
            let path = UIBezierPath(arcCenter: center, radius: 8, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
            self.stickBallLayer.path = path.cgPath
            self.stickBallLayer.position = CGPointMake(CGRectGetMidX(self.crossMarkLayer.frame), CGRectGetMidY(self.crossMarkLayer.frame))
            self.stickBallLayer.isHidden = false
        }

        // ALT variant: add background + pointer at touch point (replacing cross)
        if self.touchPadString == "LSPADALT" || self.touchPadString == "RSPADALT" {
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
            if self.touchPadString == "LSPADALT" || self.touchPadString == "RSPADALT" {
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
                if self.touchPadString == "LSPADALT" || self.touchPadString == "RSPADALT"{
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
        if self.touchPadString == "LSPADALT" || self.touchPadString == "RSPADALT" {
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
        
        if pressedButtonMask != previousButtonMask {
            if(pressedButtonMask & Direction.up.rawValue == Direction.up.rawValue) {
            showLrudDirectionIndicator(with: upIndicator)
            switch touchPadString {
                case "WASDPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["W"]!,Int8(KEY_ACTION_DOWN), 0)
                case "ARROWPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["UP_ARROW"]!,Int8(KEY_ACTION_DOWN), 0)
                case "DPAD": self.onScreenControls.pressDownControllerButton(UP_FLAG)
                default: break
                }
            }
            else{
                //self.upIndicator.removeFromSuperlayer()
                self.upIndicator.borderColor = UIColor.clear.cgColor
                switch touchPadString {
                case "WASDPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["W"]!,Int8(KEY_ACTION_UP), 0)
                case "ARROWPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["UP_ARROW"]!,Int8(KEY_ACTION_UP), 0)
                case "DPAD": self.onScreenControls.releaseControllerButton(UP_FLAG)
                default: break
                }
            }
            if(pressedButtonMask & Direction.down.rawValue == Direction.down.rawValue){
                showLrudDirectionIndicator(with: downIndicator)
                switch touchPadString {
                case "WASDPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["S"]!,Int8(KEY_ACTION_DOWN), 0)
                case "ARROWPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["DOWN_ARROW"]!,Int8(KEY_ACTION_DOWN), 0)
                case "DPAD": self.onScreenControls.pressDownControllerButton(DOWN_FLAG)
                default: break
                }
            }
            else{
                // self.downIndicator.removeFromSuperlayer()
                self.downIndicator.borderColor = UIColor.clear.cgColor
                switch touchPadString {
                case "WASDPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["S"]!,Int8(KEY_ACTION_UP), 0)
                case "ARROWPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["DOWN_ARROW"]!,Int8(KEY_ACTION_UP), 0)
                case "DPAD": self.onScreenControls.releaseControllerButton(DOWN_FLAG)
                default: break
                }
            }
            if(pressedButtonMask & Direction.left.rawValue == Direction.left.rawValue){
                showLrudDirectionIndicator(with: leftIndicator)
                switch touchPadString {
                case "WASDPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["A"]!,Int8(KEY_ACTION_DOWN), 0)
                case "ARROWPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["LEFT_ARROW"]!,Int8(KEY_ACTION_DOWN), 0)
                case "DPAD": self.onScreenControls.pressDownControllerButton(LEFT_FLAG)
                default: break
                }
            }
            else{
                // self.leftIndicator.removeFromSuperlayer()
                self.leftIndicator.borderColor = UIColor.clear.cgColor
                switch touchPadString {
                case "WASDPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["A"]!,Int8(KEY_ACTION_UP), 0)
                case "ARROWPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["LEFT_ARROW"]!,Int8(KEY_ACTION_UP), 0)
                case "DPAD": self.onScreenControls.releaseControllerButton(LEFT_FLAG)
                default: break
                }
            }
            if(pressedButtonMask & Direction.right.rawValue == Direction.right.rawValue){
                showLrudDirectionIndicator(with: rightIndicator)
                switch touchPadString {
                case "WASDPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["D"]!,Int8(KEY_ACTION_DOWN), 0)
                case "ARROWPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["RIGHT_ARROW"]!,Int8(KEY_ACTION_DOWN), 0)
                case "DPAD": self.onScreenControls.pressDownControllerButton(RIGHT_FLAG)
                default: break
                }
            }
            else{
                // self.rightIndicator.removeFromSuperlayer()
                self.rightIndicator.borderColor = UIColor.clear.cgColor
                switch touchPadString {
                case "WASDPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["D"]!,Int8(KEY_ACTION_UP), 0)
                case "ARROWPAD": LiSendKeyboardEvent(CommandManager.keyboardButtonMappings["RIGHT_ARROW"]!,Int8(KEY_ACTION_UP), 0)
                case "DPAD": self.onScreenControls.releaseControllerButton(RIGHT_FLAG)
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

    private func handleMotionControlButtonDown() {
        guard !self.motionControlButtonString.isEmpty, !self.motionButtonHeld else { return }
        switch self.motionControlButtonString {
        case "GYRO":      self.onScreenControls.pushMotionButtonHold()
        case "GYROPAUSE": self.onScreenControls.pushMotionButtonPause()
        default: return
        }
        self.motionButtonHeld = true
    }

    private func handleMotionControlButtonUp() {
        guard !self.motionControlButtonString.isEmpty, self.motionButtonHeld else { return }
        switch self.motionControlButtonString {
        case "GYRO":      self.onScreenControls.popMotionButtonHold()
        case "GYROPAUSE": self.onScreenControls.popMotionButtonPause()
        default: break
        }
        self.motionButtonHeld = false
    }

    //==== wholeButtonPress visual effect=============================================
    private func handleButtonDown() {
        if !OnScreenWidgetView.editMode && !CommandManager.specialOverlayButtonCmds.contains(self.cmdString) {
            self.sendComboButtonsDownEvent(comboStrings: self.comboButtonStrings)
            self.handleMotionControlButtonDown()
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
        if !OnScreenWidgetView.editMode && !CommandManager.specialOverlayButtonCmds.contains(self.cmdString) {
            self.sendComboButtonsUpEvent(comboStrings: self.comboButtonStrings)
            self.handleMotionControlButtonUp()
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

    private func sendRightStickTouchPadEvent(inputX: CGFloat, inputY: CGFloat){
        // Flip on the source axis so the deadband / response-curve / clamp all
        // operate consistently with the post-flip sign. Flipping after the
        // post-deadband transform would invert minStickOffset's tie-at-zero
        // bias, producing -minStickOffset when the finger is exactly centered.
        var adjX = self.stickInvertHorizontal ? -inputX : inputX
        var adjY = self.stickInvertVertical ? -inputY : inputY
        if self.touchPadString == "RSPADALT" { // circular clamp for ALT variant
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
        self.onScreenControls.sendRightStickTouchPadEvent(targetX, targetY)
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
    private func sendComboButtonsDownEvent(comboStrings: [String]) {
        DispatchQueue.global(qos: .userInteractive).async {
            for comboString in comboStrings {
                if CommandManager.oscButtonMappings.keys.contains(comboString) {
                    self.sendOscButtonDownEvent(oscString: comboString)
                }
                if CommandManager.keyboardButtonMappings.keys.contains(comboString) {
                    LiSendKeyboardEvent(CommandManager.keyboardButtonMappings[comboString]!,Int8(KEY_ACTION_DOWN), 0)
                }
                if CommandManager.mouseButtonMappings.keys.contains(comboString) {
                    LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), Int32(CommandManager.mouseButtonMappings[comboString]!))
                }
                if comboString != comboStrings.last {
                    usleep(self.comboKeyTimeIntervalMs*1000) // delay xxx ms
                }
            }
        }
    }

    private func sendComboButtonsUpEvent(comboStrings: [String]) {
        DispatchQueue.global(qos: .userInteractive).async {
            for comboString in comboStrings {
                if CommandManager.oscButtonMappings.keys.contains(comboString) {
                    self.sendOscButtonUpEvent(oscString: comboString)
                }
                if CommandManager.keyboardButtonMappings.keys.contains(comboString) {
                    LiSendKeyboardEvent(CommandManager.keyboardButtonMappings[comboString]!,Int8(KEY_ACTION_UP), 0)
                }
                if CommandManager.mouseButtonMappings.keys.contains(comboString) {
                    LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), Int32(CommandManager.mouseButtonMappings[comboString]!))
                }
                if comboString != comboStrings.last {
                    usleep(self.comboKeyTimeIntervalMs*1000) // delay xxx ms
                }
            }
        }
    }
    
//==============================================================================
    // Touch event handling
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if OnScreenWidgetView.gesturesSuppressed {
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
        self.touchBegan = true
        self.firstTouchMoved = false
        super.touchesBegan(touches, with: event)
        // self.isMultipleTouchEnabled = self.touchPadString == "MOUSEPAD" // only enable multi-touch in mousePad mode
        self.isMultipleTouchEnabled = self.widgetType == WidgetTypeEnum.button

        if !OnScreenWidgetView.editMode && self.touchPadString == "TRACKBALL" {
            stopTrackballMomentum()
        }
        
        if touches.count == 1 { // to make sure touchBegan location captured properly, don't use event.alltouches.count here
            let currentTime = CACurrentMediaTime()
            touchTapTimeInterval = currentTime - touchTapTimeStamp
            touchTapTimeStamp = currentTime
            quickDoubleTapDetected = touchTapTimeInterval < QUICK_TAP_TIME_INTERVAL
            
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
                
        let allCapturedTouchesCount = event?.allTouches?.filter({ $0.view == self }).count // this will counts all valid touches within the self widgetView, and excludes touches in other widgetViews
        if allCapturedTouchesCount == 2 {
            self.twoTouchesDetected = true
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
                    self.showStickIndicator()
                    if quickDoubleTapDetected {
                        self.showl3r3Indicator()
                        self.sendComboButtonsDownEvent(comboStrings: self.comboButtonStrings)}
                    // 对于 Alt 版本，降低相关控件透明度
                    if self.touchPadString == "LSPADALT" && !OnScreenWidgetView.obscuredByAlpha {
                        self.dimControlsForAltPad()
                    }
                case "RSPAD", "RSPADALT":
                    self.showStickIndicator()
                    if quickDoubleTapDetected {
                        self.showl3r3Indicator()
                        self.sendComboButtonsDownEvent(comboStrings: self.comboButtonStrings)}
                    // 对于 Alt 版本，降低相关控件透明度
                    if self.touchPadString == "RSPADALT" && !OnScreenWidgetView.obscuredByAlpha {
                        self.dimControlsForAltPad()
                    }
                case "LSVPAD":
                    if quickDoubleTapDetected {
                        self.showl3r3Indicator()
                        self.sendComboButtonsDownEvent(comboStrings: self.comboButtonStrings)}
                case "RSVPAD":
                    if quickDoubleTapDetected {
                        self.showl3r3Indicator()
                        self.sendComboButtonsDownEvent(comboStrings: self.comboButtonStrings)}
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
                    if quickDoubleTapDetected {
                        self.showl3r3Indicator()
                        self.sendComboButtonsDownEvent(comboStrings: self.comboButtonStrings)
                    }
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
            // handleButtonDown and the gyro would never toggle.
            if self.widgetType == WidgetTypeEnum.button &&
               (!self.comboButtonStrings.isEmpty || !self.motionControlButtonString.isEmpty) {
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

    
    private func handleButtonSlidingUp(touches: Set<UITouch>) {
        for touch in touches {
            for subview in self.superview?.subviews ?? [] {
                if let widget = subview as? OnScreenWidgetView{
                    if !widget.capturedTouches.contains(touch) || widget.slideMode == ButtonSlideMode.disabled.rawValue {continue}
                    widget.handlebuttonUp()
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
        super.touchesMoved(touches, with: event)
        if !OnScreenWidgetView.editMode {
            
            if !self.touchPadString.isEmpty{
                handleTouchPadMoveEvent(touches, with: event)
            }
            
            if !self.buttonString.isEmpty{
                if self.slideMode != ButtonSlideMode.disabled.rawValue {self.handleButtonSliding(touches: touches)}
            }
            
            if CommandManager.specialOverlayButtonCmds.contains(self.cmdString){
                if let touch = touches.first {
                    NSLog("touchTapTimeStamp %f", self.touchTapTimeStamp)
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
        self.latestTouchLocation = currentTouchLocation
    }
    
    private func handleTouchPadMoveEvent (_ touches: Set<UITouch>, with event: UIEvent?){
        if touches.count == 1{ // don't use event.alltouches.count here, it will counts all touches
            switch self.touchPadString{
            case "MOUSEPAD":
                DispatchQueue.global(qos: .userInteractive).async {
                    self.updateTouchLocation(touch: touches.first!)
                    LiSendMouseMoveEvent(Int16(truncatingIfNeeded: Int(self.deltaX * 1.7 * self.sensitivityFactorX)), Int16(truncatingIfNeeded: Int(self.deltaY * 1.7 * self.sensitivityFactorY)))
                }
                break
            case "TRACKBALL":
                DispatchQueue.global(qos: .userInteractive).async {
                    self.updateTouchLocation(touch: touches.first!)
                    LiSendMouseMoveEvent(Int16(truncatingIfNeeded: Int(self.deltaX * 1.7 * self.sensitivityFactorX)), Int16(truncatingIfNeeded: Int(self.deltaY * 1.7 * self.sensitivityFactorY)))
                    self.trackballVelocity = CGPoint(x: self.deltaX * 1.7 * self.sensitivityFactorX, y: self.deltaY * 1.7 * self.sensitivityFactorY)
                    self.stopTrackballMomentum()
                }
                break
            case "LSPAD", "LSPADALT":
                self.updateTouchLocation(touch: touches.first!)
                DispatchQueue.global(qos: .userInteractive).async {
                    self.sendLeftStickTouchPadEvent(inputX: self.offSetX * self.sensitivityFactorX, inputY: self.offSetY * self.sensitivityFactorY)
                }
                if widgetType == WidgetTypeEnum.touchPad {updateStickIndicator()}
            case "RSPAD", "RSPADALT":
                self.updateTouchLocation(touch: touches.first!)
                DispatchQueue.global(qos: .userInteractive).async {
                    self.sendRightStickTouchPadEvent(inputX: self.offSetX * self.sensitivityFactorX, inputY: self.offSetY * self.sensitivityFactorY)
                }
                if widgetType == WidgetTypeEnum.touchPad {updateStickIndicator()}
            case "LSVPAD":
                DispatchQueue.global(qos: .userInteractive).async {
                    self.updateTouchLocation(touch: touches.first!)
                    self.sendLeftStickTouchPadEvent(inputX: self.deltaX*1.5167*self.sensitivityFactorX, inputY: self.deltaY*1.5167*self.sensitivityFactorY)
                }
            case "RSVPAD":
                DispatchQueue.global(qos: .userInteractive).async {
                    self.updateTouchLocation(touch: touches.first!)
                    self.sendRightStickTouchPadEvent(inputX: self.deltaX*1.5167*self.sensitivityFactorX, inputY: self.deltaY*1.5167*self.sensitivityFactorY)
                }
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
        super.touchesCancelled(touches, with: event)
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
        let hasActiveInput = self.pressed
            || self.motionButtonHeld
            || self.capturedTouches.count > 0
            || self.activePointerIds.count > 0
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
            if !comboButtonStrings.isEmpty {
                sendComboButtonsUpEvent(comboStrings: comboButtonStrings)
            }

            switch touchPadString {
            case "LSPAD", "LSPADALT":
                onScreenControls.clearLeftStickTouchPadFlag()
                resetStickBallPositionAndHideIndicator()
            case "RSPAD", "RSPADALT":
                onScreenControls.clearRightStickTouchPadFlag()
                resetStickBallPositionAndHideIndicator()
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
        mousePointerMoved = false
        quickDoubleTapDetected = false
        restoreAlphaAfterRelease = false
        // Drop any captured touch references — touchesEnded clears these on the
        // happy path, but cancellation never gets there. Stale entries would
        // confuse the next slide-capture pass.
        capturedTouches.removeAllObjects()

        if OnScreenWidgetView.obscuredByAlpha || superview?.alpha ?? 1.0 < 0.05 {
            self.alpha = 0.02
        } else {
            tweakAlpha()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
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
        self.touchBegan = false
        super.touchesEnded(touches, with: event)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        // for checking stationary touch points

        if self.touchPadString != "MOUSEPAD" {quickDoubleTapDetected = false} //do not reset this flag here in mousePad mode
        
        let allCapturedTouchesCount = event?.allTouches?.filter({ $0.view == self }).count // this will counts all valid touches within the self widgetView, and excludes touches in other widgetViews
        
        
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
            switch self.touchPadString{
            case "LSPAD", "LSPADALT":
                self.onScreenControls.clearLeftStickTouchPadFlag()
                if widgetType == WidgetTypeEnum.touchPad {self.resetStickBallPositionAndHideIndicator()}
                // 对于 Alt 版本，恢复相关控件透明度
                if self.touchPadString == "LSPADALT" && !OnScreenWidgetView.obscuredByAlpha {
                    self.restoreControlsOpacity()
                }
            case "RSPAD", "RSPADALT":
                self.onScreenControls.clearRightStickTouchPadFlag()
                if widgetType == WidgetTypeEnum.touchPad {self.resetStickBallPositionAndHideIndicator()}
                // 对于 Alt 版本，恢复相关控件透明度
                if self.touchPadString == "RSPADALT" && !OnScreenWidgetView.obscuredByAlpha {
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
                                
        if !OnScreenWidgetView.editMode && !self.cmdString.contains("+") && !self.comboButtonStrings.isEmpty { // if the command(keystring contains "+", it's a legacy multi-key command
            self.handleButtonSlidingUp(touches: touches)
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
                case "LSPAD", "LSPADALT", "RSPAD", "RSPADALT":
                    self.showStickIndicator()
                    self.updateStickIndicator()
                default: break
                }
            }
        }
        
        self.handlebuttonUp()
        // Restore alpha if we highlighted in touchesBegan
        if restoreAlphaAfterRelease && (OnScreenWidgetView.obscuredByAlpha || self.superview?.alpha ?? 1.0 < 0.05) {
            self.alpha = 0.02
            restoreAlphaAfterRelease = false
        }
    }
    
}
