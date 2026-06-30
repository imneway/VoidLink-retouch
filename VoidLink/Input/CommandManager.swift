//
//  KeyManager.swift
//  VoidLink
//
//  Created by True砖家 on 2024/7/23.
//  Copyright © 2024 True砖家 on Bilibili. All rights reserved.
//

import Foundation
import UIKit

// Define the RemoteCommand class
@objc public class RemoteCommand: NSObject, NSSecureCoding {
    // MARK: - NSSecureCoding

    public static var supportsSecureCoding: Bool {
        return true
    }
    
    // MARK: - Properties
    
    @objc var cmdString: String
    @objc var alias: String
    
    // MARK: - Initialization

    init(cmdString: String, alias: String) {
        self.cmdString = cmdString
        self.alias = alias
    }

    // MARK: - NSSecureCoding

    required public init?(coder: NSCoder) {
        guard let cmdString = coder.decodeObject(of: NSString.self, forKey: "keyboardCmdString") as String?,
              let alias = coder.decodeObject(of: NSString.self, forKey: "alias") as String? else {
            return nil
        }
        self.cmdString = cmdString
        self.alias = alias
    }

    public func encode(with coder: NSCoder) {
        coder.encode(cmdString, forKey: "keyboardCmdString")
        coder.encode(alias, forKey: "alias")
    }
}


// Define the CommandManager class
@objc public class CommandManager: NSObject {
    @objc public static let shared = CommandManager()
    
    @objc public static let mouseButtonMappings: [String: Int32] = [
        "M_LEFT" : BUTTON_LEFT,
        "MLEFT" : BUTTON_LEFT,
        "M_MIDDLE" : BUTTON_MIDDLE,
        "MMIDDLE" : BUTTON_MIDDLE,
        "M_RIGHT" : BUTTON_RIGHT,
        "MRIGHT" : BUTTON_RIGHT,
        "M_X1" : BUTTON_X1,
        "MX1" : BUTTON_X1,
        "M_X2" : BUTTON_X2,
        "MX2" : BUTTON_X2
    ]
    
    
    @objc public static let oscButtonMappings: [String: Int32] = [
        "OSCA" : A_FLAG,
        "OSCB" : B_FLAG,
        "OSCX" : X_FLAG,
        "OSCY" : Y_FLAG,
        "OSCL1" : LB_FLAG,
        "L1" : LB_FLAG,
        "LB" : LB_FLAG,
        "OSCR1" : RB_FLAG,
        "R1" : RB_FLAG,
        "RB" : RB_FLAG,
        "OSCL3" : LS_CLK_FLAG,
        "L3" : LS_CLK_FLAG,
        "LS" : LS_CLK_FLAG,
        "OSCR3" : RS_CLK_FLAG,
        "R3" : RS_CLK_FLAG,
        "RS" : RS_CLK_FLAG,
        "OSCSTART" : PLAY_FLAG,
        "OSCPLAY" : PLAY_FLAG,
        "OSCSELECT" : BACK_FLAG,
        "OSCBACK" : BACK_FLAG,
        "OSCUP" : UP_FLAG,
        "OSCDOWN" : DOWN_FLAG,
        "OSCLEFT" : LEFT_FLAG,
        "OSCRIGHT" : RIGHT_FLAG,
        "DS4TCHBTN" : TOUCHPAD_FLAG,
        "PADDLE1" : PADDLE1_FLAG,
        "PADDLE2" : PADDLE2_FLAG,
        "PADDLE3" : PADDLE3_FLAG,
        "PADDLE4" : PADDLE4_FLAG,
        "MISC" : MISC_FLAG,
        "OSCL2" : 0,
        "L2" : 0,
        "LT" : 0,
        "OSCR2" : 0,
        "R2" : 0,
        "RT" : 0
    ]

    @objc public static let oscRectangleButtonCmds: [String] = [
        "OSCUP",
        "OSCDOWN",
        "OSCLEFT",
        "OSCRIGHT",
        "OSCSTART",
        "OSCPLAY",
        "OSCSELECT",
        "OSCBACK"
    ]
    
    @objc public static let touchPadCmds: [String] = ["LSVPAD", "RSVPAD", "LSPAD", "LSPADALT", "RSPAD", "RSPADALT", "RSPADALT2", "DS4TOUCH", "MOUSEPAD", "DPAD", "TRACKBALL", "WASDPAD", "ARROWPAD"]
    @objc public static let directionPads: [String] = ["DPAD", "WASDPAD", "ARROWPAD"]
    @objc public static let stickTouchPads: [String] = ["LSVPAD", "RSVPAD", "LSPAD", "LSPADALT", "RSPAD", "RSPADALT", "RSPADALT2"]
    @objc public static let nonVectorStickPads: [String] = ["LSPAD", "LSPADALT", "RSPAD", "RSPADALT", "RSPADALT2"]
    @objc public static let specialOverlayButtonCmds: [String] = ["SETTINGS", "CMD"]

    // Motion-control command tokens. A widget cmdString containing one of these
    // gates the runtime gyro emission rather than firing a normal button event.
    // GYRO       — hold to keep gyro events flowing; release to suspend.
    // GYROPAUSE  — inverse: hold to pause; release to resume. Useful as an
    //              emergency-stop overlay when gyro is otherwise always-on.
    // Combo with regular buttons (e.g. "OSCR2+GYRO") fires R2 to host AND
    // toggles the gyro at the same time.
    @objc public static let motionControlButtonCmds: [String] = ["GYRO", "GYROPAUSE"]

    @objc public static let physicalControllerComboDefaultsKey = "physicalControllerComboMappingsV1"
    @objc public static let physicalControllerComboDidChangeNotification = "PhysicalControllerComboMappingsDidChangeNotification"
    @objc public static let physicalControllerComboSources: [String] = [
        "A", "B", "X", "Y",
        "L1", "R1", "L2", "R2",
        "L3", "R3",
        "START", "SELECT", "HOME",
        "UP", "DOWN", "LEFT", "RIGHT",
        "PADDLE1", "PADDLE2", "PADDLE3", "PADDLE4",
        "SHARE", "TOUCHPAD"
    ]
    @objc public static let physicalControllerComboTargets: [String] = [
        "OSCA", "OSCB", "OSCX", "OSCY",
        "OSCL1", "OSCR1", "OSCL2", "OSCR2",
        "OSCL3", "OSCR3",
        "OSCSTART", "OSCSELECT",
        "OSCUP", "OSCDOWN", "OSCLEFT", "OSCRIGHT",
        "PADDLE1", "PADDLE2", "PADDLE3", "PADDLE4",
        "MISC", "DS4TCHBTN"
    ]

    @objc public static let aimRelativeActivationOff = "OFF"
    @objc public static let aimRelativeActivationOn = "ON"
    @objc public static let aimRelativeActivationControllerButtons: [String] = [
        "OSCA", "OSCB", "OSCX", "OSCY",
        "OSCL1", "OSCR1", "OSCL2", "OSCR2",
        "OSCL3", "OSCR3",
        "OSCSTART", "OSCSELECT",
        "OSCUP", "OSCDOWN", "OSCLEFT", "OSCRIGHT"
    ]
    @objc public static let aimRelativeActivationOptions: [String] =
        [aimRelativeActivationOn, aimRelativeActivationOff] + aimRelativeActivationControllerButtons

    @objc(aimRelativeActivationTitleForCommand:)
    public static func aimRelativeActivationTitle(for command: String) -> String {
        switch normalizedAimRelativeActivationCommand(command) {
        case aimRelativeActivationOn: return "Turn ON"
        case aimRelativeActivationOff: return "Turn OFF"
        case "OSCA": return "A"
        case "OSCB": return "B"
        case "OSCX": return "X"
        case "OSCY": return "Y"
        case "OSCL1": return "L1"
        case "OSCR1": return "R1"
        case "OSCL2": return "L2 / LT"
        case "OSCR2": return "R2 / RT"
        case "OSCL3": return "L3"
        case "OSCR3": return "R3"
        case "OSCSTART": return "Start"
        case "OSCSELECT": return "Select"
        case "OSCUP": return "D-Pad Up"
        case "OSCDOWN": return "D-Pad Down"
        case "OSCLEFT": return "D-Pad Left"
        case "OSCRIGHT": return "D-Pad Right"
        default: return "Turn OFF"
        }
    }

    @objc(normalizedAimRelativeActivationCommand:)
    public static func normalizedAimRelativeActivationCommand(_ command: String?) -> String {
        let raw = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch raw {
        case "", aimRelativeActivationOff, "TURN OFF":
            return aimRelativeActivationOff
        case aimRelativeActivationOn, "TURN ON":
            return aimRelativeActivationOn
        case "A":
            return "OSCA"
        case "B":
            return "OSCB"
        case "X":
            return "OSCX"
        case "Y":
            return "OSCY"
        case "L1", "LB":
            return "OSCL1"
        case "R1", "RB":
            return "OSCR1"
        case "L2", "LT":
            return "OSCL2"
        case "R2", "RT":
            return "OSCR2"
        case "L3", "LS":
            return "OSCL3"
        case "R3", "RS":
            return "OSCR3"
        case "START", "PLAY", "OSCPLAY":
            return "OSCSTART"
        case "SELECT", "BACK", "OSCBACK":
            return "OSCSELECT"
        case "UP":
            return "OSCUP"
        case "DOWN":
            return "OSCDOWN"
        case "LEFT":
            return "OSCLEFT"
        case "RIGHT":
            return "OSCRIGHT"
        default:
            return aimRelativeActivationOptions.contains(raw) ? raw : aimRelativeActivationOff
        }
    }

    // @objc public static let specialGameWidgets: [String] = ["YSRSV", "YSLT", "YSRT", "YSRB", "YSB", "YSRT2", "YSRB2", "YSB2", "YSEM", "YSML", "YSMR", "YSWASD"]
    
    static let keyboardButtonMappings: [String: Int16] = [
        // Windows Key Codes
        "NULL": 0xFF,
        "CTRL": 0x11,        // VK_CONTROL
        "SHIFT": 0x10,       // VK_SHIFT
        "ALT": 0x12,         // VK_MENU
        "F1": 0x70,          // VK_F1
        "F2": 0x71,          // VK_F2
        "F3": 0x72,          // VK_F3
        "F4": 0x73,          // VK_F4
        "F5": 0x74,          // VK_F5
        "F6": 0x75,          // VK_F6
        "F7": 0x76,          // VK_F7
        "F8": 0x77,          // VK_F8
        "F9": 0x78,          // VK_F9
        "F10": 0x79,         // VK_F10
        "F11": 0x7A,         // VK_F11
        "F12": 0x7B,         // VK_F12
        "F13": 0x7C,         // VK_F13
        "F14": 0x7D,         // VK_F14
        "F15": 0x7E,         // VK_F15
        "F16": 0x80,         // VK_F16
        "F17": 0x81,         // VK_F17
        "F18": 0x82,         // VK_F18
        "F19": 0x83,         // VK_F19
        "A": 0x41,           // 'A' key
        "B": 0x42,           // 'B' key
        "C": 0x43,           // 'C' key
        "D": 0x44,           // 'D' key
        "E": 0x45,           // 'E' key
        "F": 0x46,           // 'F' key
        "G": 0x47,           // 'G' key
        "H": 0x48,           // 'H' key
        "I": 0x49,           // 'I' key
        "J": 0x4A,           // 'J' key
        "K": 0x4B,           // 'K' key
        "L": 0x4C,           // 'L' key
        "M": 0x4D,           // 'M' key
        "N": 0x4E,           // 'N' key
        "O": 0x4F,           // 'O' key
        "P": 0x50,           // 'P' key
        "Q": 0x51,           // 'Q' key
        "R": 0x52,           // 'R' key
        "S": 0x53,           // 'S' key
        "T": 0x54,           // 'T' key
        "U": 0x55,           // 'U' key
        "V": 0x56,           // 'V' key
        "W": 0x57,           // 'W' key
        "X": 0x58,           // 'X' key
        "Y": 0x59,           // 'Y' key
        "Z": 0x5A,           // 'Z' key
        "0": 0x30,           // '0' key
        "1": 0x31,           // '1' key
        "2": 0x32,           // '2' key
        "3": 0x33,           // '3' key
        "4": 0x34,           // '4' key
        "5": 0x35,           // '5' key
        "6": 0x36,           // '6' key
        "7": 0x37,           // '7' key
        "8": 0x38,           // '8' key
        "9": 0x39,           // '9' key
        "ESC": 0x1B,         // VK_ESCAPE
        "SPACE": 0x20,       // VK_SPACE
        "ENTER": 0x0D,       // VK_RETURN
        "TAB": 0x09,         // VK_TAB
        "BACKSPACE": 0x08,   // VK_BACK
        "INSERT": 0x2D,      // VK_INSERT
        "DEL": 0x2E,      // VK_DELETE
        "HOME": 0x24,        // VK_HOME
        "END": 0x23,         // VK_END
        "PG_UP": 0x21,     // VK_PRIOR
        "PGUP": 0x21,     // VK_PRIOR
        "PG_DOWN": 0x22,   // VK_NEXT
        "PGDOWN": 0x22,   // VK_NEXT
        "PGDN": 0x22,   // VK_NEXT
        "UP_ARROW": 0x26,    // VK_UP
        "UPARR": 0x26,    // VK_UP
        "DOWN_ARROW": 0x28,  // VK_DOWN
        "DOWNARR": 0x28,  // VK_DOWN
        "LEFT_ARROW": 0x25,  // VK_LEFT
        "LEFTARR": 0x25,  // VK_LEFT
        "RIGHT_ARROW": 0x27, // VK_RIGHT
        "RIGHTARR": 0x27, // VK_RIGHT
        "NUM_LCK": 0x90,    // VK_NUMLOCK
        "NUMLCK": 0x90,    // VK_NUMLOCK
        "SCR_LCK": 0x91, // VK_SCROLL
        "SCRLCK": 0x91, // VK_SCROLL
        "CAPS_LOCK": 0x14,   // VK_CAPITAL
        "CAPSLOCK": 0x14,   // VK_CAPITAL
        "PAUSE": 0x13,       // VK_PAUSE
        "PR_SCR": 0x2C, // VK_SNAPSHOT
        "PRSCR": 0x2C, // VK_SNAPSHOT
        "NUMPAD0": 0x60,     // VK_NUMPAD0
        "NUMPAD1": 0x61,     // VK_NUMPAD1
        "NUMPAD2": 0x62,     // VK_NUMPAD2
        "NUMPAD3": 0x63,     // VK_NUMPAD3
        "NUMPAD4": 0x64,     // VK_NUMPAD4
        "NUMPAD5": 0x65,     // VK_NUMPAD5
        "NUMPAD6": 0x66,     // VK_NUMPAD6
        "NUMPAD7": 0x67,     // VK_NUMPAD7
        "NUMPAD8": 0x68,     // VK_NUMPAD8
        "NUMPAD9": 0x69,     // VK_NUMPAD9
        "MULTIPLY": 0x6A,    // VK_MULTIPLY
        "ADD": 0x6B,         // VK_ADD
        "SUBTRACT": 0x6D,    // VK_SUBTRACT
        "DECIMAL": 0x6E,     // VK_DECIMAL
        "DIVIDE": 0x6F,      // VK_DIVIDE
        "SEMI_COLON": 0xBA,  // VK_OEM_1
        "SEMICOLON": 0xBA,  // VK_OEM_1
        "EQUALS": 0xBB,      // VK_OEM_PLUS
        "COMMA": 0xBC,       // VK_OEM_COMMA
        "MINUS": 0xBD,       // VK_OEM_MINUS
        "PERIOD": 0xBE,      // VK_OEM_PERIOD
        "FORWARD_SLASH": 0xBF, // VK_OEM_2
        "FORWARDSLASH": 0xBF, // VK_OEM_2
        "GRAVE_ACCENT": 0xC0, // VK_OEM_3
        "GRAVEACCENT": 0xC0, // VK_OEM_3
        "OPEN_BRACKET": 0xDB, // VK_OEM_4
        "OPENBRACKET": 0xDB, // VK_OEM_4
        "BACKSLASH": 0xDC,   // VK_OEM_5
        "CLOSE_BRACKET": 0xDD, // VK_OEM_6
        "CLOSEBRACKET": 0xDD, // VK_OEM_6
        "SINGLE_QUOTE": 0xDE, // VK_OEM_7
        "SINGLEQUOTE": 0xDE, // VK_OEM_7
        "VOLUME_MUTE": 0xAD, // VK_VOLUME_MUTE
        "VOLMUTE": 0xAD, // VK_VOLUME_MUTE
        "VOLUME_DOWN": 0xAE, // VK_VOLUME_DOWN
        "VOLDOWN": 0xAE, // VK_VOLUME_DOWN
        "VOLUME_UP": 0xAF,   // VK_VOLUME_UP
        "VOLUP": 0xAF,   // VK_VOLUME_UP
        "MEDIA_NEXT": 0xB0,  // VK_MEDIA_NEXT_TRACK
        "MEDIANEXT": 0xB0,  // VK_MEDIA_NEXT_TRACK
        "MEDIA_PREV": 0xB1,  // VK_MEDIA_PREV_TRACK
        "MEDIAPREV": 0xB1,  // VK_MEDIA_PREV_TRACK
        "MEDIA_STOP": 0xB2,  // VK_MEDIA_STOP
        "MEDIASTOP": 0xB2,  // VK_MEDIA_STOP
        "MEDIA_PLAY_PAUSE": 0xB3, // VK_MEDIA_PLAY_PAUSE
        "PLAYPAUSE": 0xB3, // VK_MEDIA_PLAY_PAUSE
        "LAUNCH_MAIL": 0xB4, // VK_LAUNCH_MAIL
        "LAUNCHMAIL": 0xB4, // VK_LAUNCH_MAIL
        "LAUNCH_MEDIA_SELECT": 0xB5, // VK_LAUNCH_MEDIA_SELECT
        "MEDIA_SELECT": 0xB5, // VK_LAUNCH_MEDIA_SELECT
        "LAUNCH_APP1": 0xB6, // VK_LAUNCH_APP1
        "LAUNCHAPP1": 0xB6, // VK_LAUNCH_APP1
        "LAUNCH_APP2": 0xB7, // VK_LAUNCH_APP2
        "LAUNCHAPP2": 0xB7, // VK_LAUNCH_APP2
        "WIN":  0x5B,
        "LEFT_WIN": 0x5B, // VK_LWIN
        "RIGHT_WIN": 0x5C, // VK_RWIN
        "RIGHTWIN": 0x5C, // VK_RWIN
        "APPS": 0x5D,        // VK_APPS
        
        // macOS Key Codes
        "CMD": 0x37,     // ⌘ Command
        "OPT": 0x3A,      // ⌥ Option
        "CONTROL": 0x3B,     // ⌃ Control
        "FUNCTION": 0x3F,    // fn
        "SHIFTMAC": 0x38,   // ⇧ Shift
        "DELETEMAC": 0x75,  // Forward Delete
        "RETURNMAC": 0x24,  // Return
        "ENTERMAC": 0x4C,   // Enter
        "ESCAPEMAC": 0x35,  // Escape
        "TABMAC": 0x30,     // Tab
        "SPACEMAC": 0x31,   // Space
        "UPARRMAC": 0x7E,  // Up Arrow
        "DOWNARRMAC": 0x7D, // Down Arrow
        "LEFTARRMAC": 0x7B, // Left Arrow
        "RIGHTARRMAC": 0x7C, // Right Arrow
        "F1MAC": 0x7A,      // F1
        "F2MAC": 0x78,      // F2
        "F3MAC": 0x63,      // F3
        "F4MAC": 0x76,      // F4
        "F5MAC": 0x60,      // F5
        "F6MAC": 0x61,      // F6
        "F7MAC": 0x62,      // F7
        "F8MAC": 0x64,      // F8
        "F9MAC": 0x65,      // F9
        "F10MAC": 0x6D,     // F10
        "F11MAC": 0x67,     // F11
        "F12MAC": 0x6F,     // F12
        "0MAC": 0x52,       // 0
        "1MAC": 0x53,       // 1
        "2MAC": 0x54,       // 2
        "3MAC": 0x55,       // 3
        "4MAC": 0x56,       // 4
        "5MAC": 0x57,       // 5
        "6MAC": 0x58,       // 6
        "7MAC": 0x59,       // 7
        "8MAC": 0x5A,       // 8
        "9MAC": 0x5B,       // 9
        "NUMPAD0MAC": 0x4F, // Numpad 0
        "NUMPAD1MAC": 0x50, // Numpad 1
        "NUMPAD2MAC": 0x51, // Numpad 2
        "NUMPAD3MAC": 0x52, // Numpad 3
        "NUMPAD4MAC": 0x53, // Numpad 4
        "NUMPAD5MAC": 0x54, // Numpad 5
        "NUMPAD6MAC": 0x55, // Numpad 6
        "NUMPAD7MAC": 0x56, // Numpad 7
        "NUMPAD8MAC": 0x57, // Numpad 8
        "NUMPAD9MAC": 0x58, // Numpad 9
        "NUMPADADDMAC": 0x45,  // Numpad Add
        "NUMPADSUBTRACTMAC": 0x4A, // Numpad Subtract
        "NUMPADMULTIPLYMAC": 0x43, // Numpad Multiply
        "NUMPADDIVIDEMAC": 0x4B, // Numpad Divide
        "NUMPADDECIMALMAC": 0x41, // Numpad Decimal
        "SHIFT_MAC": 0x38,   // ⇧ Shift
        "DELETE_MAC": 0x75,  // Forward Delete
        "RETURN_MAC": 0x24,  // Return
        "ENTER_MAC": 0x4C,   // Enter
        "ESCAPE_MAC": 0x35,  // Escape
        "TAB_MAC": 0x30,     // Tab
        "SPACE_MAC": 0x31,   // Space
        "UP_ARROW_MAC": 0x7E,  // Up Arrow
        "DOWN_ARROW_MAC": 0x7D, // Down Arrow
        "LEFT_ARROW_MAC": 0x7B, // Left Arrow
        "RIGHT_ARROW_MAC": 0x7C, // Right Arrow
        "F1_MAC": 0x7A,      // F1
        "F2_MAC": 0x78,      // F2
        "F3_MAC": 0x63,      // F3
        "F4_MAC": 0x76,      // F4
        "F5_MAC": 0x60,      // F5
        "F6_MAC": 0x61,      // F6
        "F7_MAC": 0x62,      // F7
        "F8_MAC": 0x64,      // F8
        "F9_MAC": 0x65,      // F9
        "F10_MAC": 0x6D,     // F10
        "F11_MAC": 0x67,     // F11
        "F12_MAC": 0x6F,     // F12
        "0_MAC": 0x52,       // 0
        "1_MAC": 0x53,       // 1
        "2_MAC": 0x54,       // 2
        "3_MAC": 0x55,       // 3
        "4_MAC": 0x56,       // 4
        "5_MAC": 0x57,       // 5
        "6_MAC": 0x58,       // 6
        "7_MAC": 0x59,       // 7
        "8_MAC": 0x5A,       // 8
        "9_MAC": 0x5B,       // 9
        "NUMPAD0_MAC": 0x4F, // Numpad 0
        "NUMPAD1_MAC": 0x50, // Numpad 1
        "NUMPAD2_MAC": 0x51, // Numpad 2
        "NUMPAD3_MAC": 0x52, // Numpad 3
        "NUMPAD4_MAC": 0x53, // Numpad 4
        "NUMPAD5_MAC": 0x54, // Numpad 5
        "NUMPAD6_MAC": 0x55, // Numpad 6
        "NUMPAD7_MAC": 0x56, // Numpad 7
        "NUMPAD8_MAC": 0x57, // Numpad 8
        "NUMPAD9_MAC": 0x58, // Numpad 9
        "NUMPAD_ADD_MAC": 0x45,  // Numpad Add
        "NUMPAD_SUBTRACT_MAC": 0x4A, // Numpad Subtract
        "NUMPAD_MULTIPLY_MAC": 0x43, // Numpad Multiply
        "NUMPAD_DIVIDE_MAC": 0x4B, // Numpad Divide
        "NUMPAD_DECIMAL_MAC": 0x41, // Numpad Decimal
    ]
    
    private var commands: [RemoteCommand] = []
    
    public weak var viewController: ToolboxViewController?
    
    private override init() {
        super.init()
        loadCommands()
    }
    
    @objc static func presetDefaultCommands() {
        let defaults = UserDefaults.standard
        //if true {  // save default entries if the data is empty.
        if defaults.data(forKey: "savedCommands") == nil {  // save default entries if the data is empty.
            var defaultCommands: [RemoteCommand] = [
                RemoteCommand(cmdString: "WIN", alias: "WIN"),
                RemoteCommand(cmdString: "F11", alias: "F11"),
                RemoteCommand(cmdString: "ESC", alias: "ESC"),
                RemoteCommand(cmdString: "CTRL+SHIFT+ESC", alias: "任务管理器(Task Manager)"),
                RemoteCommand(cmdString: "ALT+F1", alias: "N卡截图(Nvidia Screenshot)"),
                RemoteCommand(cmdString: "ALT+F9", alias: "N卡录屏(Nvidia Screen Recording)"),
                RemoteCommand(cmdString: "ALT+F4", alias: "关闭窗口(ALT+F4)"),
                RemoteCommand(cmdString: "CTRL+A", alias: "全选(Select All)"),
                RemoteCommand(cmdString: "CTRL+C", alias: "复制(Copy)"),
                RemoteCommand(cmdString: "CTRL+V", alias: "粘贴(Paste)"),
                RemoteCommand(cmdString: "WIN+D", alias: "切换桌面(Switch to Desktop)"),
                RemoteCommand(cmdString: "WIN+P", alias: "多显模式(Project)"),
                RemoteCommand(cmdString: "WIN+G", alias: "Xbox Game Bar"),
                RemoteCommand(cmdString: "SHIFT+TAB", alias: "Steam Overlay"),
            ]
            
            let data = try? NSKeyedArchiver.archivedData(withRootObject: defaultCommands, requiringSecureCoding: false)
            defaults.set(data, forKey: "savedCommands")
        }
    }
    
    @objc public func createTestKeyMappings() -> [String: Int16] {
        return CommandManager.keyboardButtonMappings
    }
    
    // extractKeyStrings from keyboardCMDString
    @objc public func extractKeyStringsFromComboCommand(from input: String) -> [String]? {
        let keys = CommandManager.keyboardButtonMappings.keys.joined(separator: "|")
        let pattern = "^(?:(\(keys))(?:\\+(\(keys))*)*)$"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            print("Failed to create regex")
            return nil
        }
        let range = NSRange(location: 0, length: input.utf16.count)
        guard let match = regex.firstMatch(in: input, options: [], range: range) else {
            print("No match found for input: \(input)")
            return nil
        }
        // print("Regex matched for input: \(input)")
        
        let matchedString = (input as NSString).substring(with: match.range(at: 0))
        let keyStrings = matchedString.split(separator: "+").map { String($0) }
        
        guard !keyStrings.isEmpty else {
            print("No key strings found in the matched string")
            return nil
        }
        
        var validKeyStrings: [String] = []
        
        for key in keyStrings {
            if CommandManager.keyboardButtonMappings.keys.contains(key) {
                validKeyStrings.append(key)
            } else {
                print(" '\(key)' is not defined in key mappings")
                return nil  //treat any illegal string as a whole
            }
        }
        
        if validKeyStrings.isEmpty {
            print("No valid key strings found in the matched string")
            return nil
        }
        
        for (index, key) in validKeyStrings.enumerated() {
            print("Valid Key \(index): \(key)")
        }
        
        return validKeyStrings
        
    }
    
    //super combo key button strings
    @objc public func extractSinglCmdStringsFromComboKeys(from input: String) -> [String]? {
        let combinedStrings =  [CommandManager.keyboardButtonMappings.keys.map { $0 as String },
                                CommandManager.oscButtonMappings.keys.map { $0 as String },
                                CommandManager.mouseButtonMappings.keys.map { $0 as String },
                                CommandManager.touchPadCmds.map { $0 as String },
                                CommandManager.motionControlButtonCmds.map { $0 as String }
                                ]
                                .lazy
                                .flatMap { $0 }  // 三维展开
                                .map(String.init(describing:)) // 安全类型转换
        
        let keys = combinedStrings.joined(separator: "|")
        let pattern = "^(?:\(keys))(?:-(?:\(keys)))*(?:-\\d+MS)?$"

        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            print("Failed to create regex")
            return nil
        }
        let range = NSRange(location: 0, length: input.utf16.count)
        guard let match = regex.firstMatch(in: input, options: [], range: range) else {
            print("No match found for input: \(input)")
            return nil
        }
        // print("Regex matched for input: \(input)")
        
        let matchedString = (input as NSString).substring(with: match.range(at: 0))
        let cmdStrings = matchedString.split(separator: "-").map { String($0) }
        
        guard !cmdStrings.isEmpty else {
            print("No key strings found in the matched string")
            return nil
        }
        
        var validCmdStrings: [String] = []
        
        for key in cmdStrings {
            validCmdStrings.append(key)
        }
       
        if validCmdStrings.isEmpty {
            print("No valid key strings found in the matched string")
            return nil
        }
        
        for (index, key) in validCmdStrings.enumerated() {
            print("Valid Key \(index): \(key)")
        }
        
        return validCmdStrings
    }

    // MARK: - Conditional widget "last activation" tracking
    //
    // Records the token set of the most recent on-screen button activation so a
    // conditional widget can decide its output from what was pressed just before it.
    // Both writers run on the main thread — legacy OSC button taps via
    // OnScreenControls.handleTouchDownEvent, and custom-widget presses via
    // OnScreenWidgetView.handleButtonDown — and the reader (handleButtonDown again)
    // is also main-thread, so no locking is needed. Each press OVERWRITES the set;
    // we only ever care about "the last press", never history.
    private var _lastActivationTokens: Set<String> = []

    // Collapses OSC aliases to one canonical spelling so the arm/record comparison matches
    // regardless of which alias the user typed (e.g. "L1"/"LB"/"OSCL1" all → "OSCL1", and
    // legacy taps recorded as "OSCL1" by armTokenForTouchLocation: line up too). Tokens with
    // no alias (OSCA, keyboard, mouse, …) pass through uppercased.
    private static let tokenCanonicalMap: [String: String] = [
        "L1": "OSCL1", "LB": "OSCL1",
        "R1": "OSCR1", "RB": "OSCR1",
        "L2": "OSCL2", "LT": "OSCL2",
        "R2": "OSCR2", "RT": "OSCR2",
        "L3": "OSCL3", "LS": "OSCL3",
        "R3": "OSCR3", "RS": "OSCR3",
        "OSCPLAY": "OSCSTART",
        "OSCBACK": "OSCSELECT"
    ]

    private static func canonicalToken(_ token: String) -> String {
        let upper = token.uppercased()
        return tokenCanonicalMap[upper] ?? upper
    }

    // Legacy single-button tap (one flag = one token).
    @objc public func recordLastActivationToken(_ token: String) {
        _lastActivationTokens = [CommandManager.canonicalToken(token)]
    }

    // Custom widget press (a combo widget fires a whole token set "together").
    @objc public func recordLastActivationTokens(_ tokens: [String]) {
        _lastActivationTokens = Set(tokens.map { CommandManager.canonicalToken($0) })
    }

    // AND / subset test: every arm token must be present in the last activation.
    public func lastActivationContainsAll(_ tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        let snapshot = _lastActivationTokens
        return tokens.allSatisfy { snapshot.contains(CommandManager.canonicalToken($0)) }
    }

    // MARK: - Conditional command syntax  —  COND:<base>:<arm>:<armedOutput>
    //
    // <base>        the button's normal binding (also the "condition not met" output)
    // <arm>         tokens that must ALL be in the last activation to arm (AND semantics)
    // <armedOutput> combo fired when armed; may carry '*' tap markers (see OnScreenWidgetView)
    // Each of the three is a normal combo string (internal '-' / trailing '<n>MS').

    @objc public func isConditionalCommand(_ input: String) -> Bool {
        return input.uppercased().hasPrefix("COND:")
    }

    // Returns [base, arm, armedOutput] (original case preserved) or nil if malformed.
    @objc public func conditionalCommandComponents(_ input: String) -> [String]? {
        let parts = input.components(separatedBy: ":")
        guard parts.count == 4, parts[0].uppercased() == "COND" else { return nil }
        guard !parts[1].isEmpty, !parts[2].isEmpty, !parts[3].isEmpty else { return nil }
        return [parts[1], parts[2], parts[3]]
    }

    // Mirrors OnScreenWidgetView.parseComboString: '*' is a tap marker only at a token's
    // END. A naive global strip would wrongly accept "O*SCR2", which the runtime then
    // can't map → silent no-op. Strip a single trailing '*' per token only.
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

    @objc public func isValidConditionalCommand(_ input: String) -> Bool {
        guard let comps = conditionalCommandComponents(input) else { return false }
        let base = comps[0], arm = comps[1], armed = comps[2]
        // armedOutput may carry '*' tap markers; base/arm normally don't, but strip
        // consistently so validation matches exactly what the runtime parser accepts.
        return extractSinglCmdStringsFromComboKeys(from: CommandManager.stripTrailingTapMarkers(base)) != nil
            && extractSinglCmdStringsFromComboKeys(from: CommandManager.stripTrailingTapMarkers(arm)) != nil
            && extractSinglCmdStringsFromComboKeys(from: CommandManager.stripTrailingTapMarkers(armed)) != nil
    }

    @objc(normalizedPhysicalControllerComboSource:)
    public static func normalizedPhysicalControllerComboSource(_ input: String?) -> String {
        let raw = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch raw {
        case "OSCA": return "A"
        case "OSCB": return "B"
        case "OSCX": return "X"
        case "OSCY": return "Y"
        case "LB", "OSCL1": return "L1"
        case "RB", "OSCR1": return "R1"
        case "LT", "OSCL2": return "L2"
        case "RT", "OSCR2": return "R2"
        case "LS", "OSCL3": return "L3"
        case "RS", "OSCR3": return "R3"
        case "PLAY", "MENU", "OSCSTART", "OSCPLAY": return "START"
        case "BACK", "OPTIONS", "OSCSELECT", "OSCBACK": return "SELECT"
        case "GUIDE", "SPECIAL": return "HOME"
        case "DUP", "D_PAD_UP", "DPAD_UP", "OSCUP": return "UP"
        case "DDOWN", "D_PAD_DOWN", "DPAD_DOWN", "OSCDOWN": return "DOWN"
        case "DLEFT", "D_PAD_LEFT", "DPAD_LEFT", "OSCLEFT": return "LEFT"
        case "DRIGHT", "D_PAD_RIGHT", "DPAD_RIGHT", "OSCRIGHT": return "RIGHT"
        case "MISC": return "SHARE"
        case "DS4TCHBTN", "TOUCHPAD_BUTTON": return "TOUCHPAD"
        default:
            return physicalControllerComboSources.contains(raw) ? raw : ""
        }
    }

    @objc(normalizedPhysicalControllerComboTarget:)
    public static func normalizedPhysicalControllerComboTarget(_ input: String?) -> String {
        let raw = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch raw {
        case "A": return "OSCA"
        case "B": return "OSCB"
        case "X": return "OSCX"
        case "Y": return "OSCY"
        case "L1", "LB": return "OSCL1"
        case "R1", "RB": return "OSCR1"
        case "L2", "LT": return "OSCL2"
        case "R2", "RT": return "OSCR2"
        case "L3", "LS": return "OSCL3"
        case "R3", "RS": return "OSCR3"
        case "START", "PLAY", "OSCPLAY": return "OSCSTART"
        case "SELECT", "BACK", "OSCBACK": return "OSCSELECT"
        case "UP": return "OSCUP"
        case "DOWN": return "OSCDOWN"
        case "LEFT": return "OSCLEFT"
        case "RIGHT": return "OSCRIGHT"
        case "SHARE": return "MISC"
        case "TOUCHPAD": return "DS4TCHBTN"
        default:
            return physicalControllerComboTargets.contains(raw) ? raw : ""
        }
    }

    @objc(physicalControllerComboTitleFor:)
    public static func physicalControllerComboTitle(for token: String) -> String {
        let source = normalizedPhysicalControllerComboSource(token)
        let normalized = source.isEmpty ? normalizedPhysicalControllerComboTarget(token) : source
        switch normalized {
        case "OSCA", "A": return "A"
        case "OSCB", "B": return "B"
        case "OSCX", "X": return "X"
        case "OSCY", "Y": return "Y"
        case "OSCL1", "L1": return "L1"
        case "OSCR1", "R1": return "R1"
        case "OSCL2", "L2": return "L2"
        case "OSCR2", "R2": return "R2"
        case "OSCL3", "L3": return "L3"
        case "OSCR3", "R3": return "R3"
        case "OSCSTART", "START": return "Start"
        case "OSCSELECT", "SELECT": return "Select"
        case "HOME": return "Home"
        case "OSCUP", "UP": return "D-Pad Up"
        case "OSCDOWN", "DOWN": return "D-Pad Down"
        case "OSCLEFT", "LEFT": return "D-Pad Left"
        case "OSCRIGHT", "RIGHT": return "D-Pad Right"
        case "PADDLE1": return "Paddle 1"
        case "PADDLE2": return "Paddle 2"
        case "PADDLE3": return "Paddle 3"
        case "PADDLE4": return "Paddle 4"
        case "MISC", "SHARE": return "Share"
        case "DS4TCHBTN", "TOUCHPAD": return "Touchpad"
        default: return token
        }
    }

    @objc(extractPhysicalControllerComboTokensFrom:)
    public static func extractPhysicalControllerComboTokens(from input: String) -> [String]? {
        let parts = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .split(separator: "-")
            .map { String($0) }
        guard !parts.isEmpty else { return nil }

        var tokens: [String] = []
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1, part.hasSuffix("MS") {
                let delayText = String(part.dropLast(2))
                if !delayText.isEmpty, delayText.allSatisfy({ $0.isNumber }) {
                    tokens.append(part)
                    continue
                }
                return nil
            }

            let normalized = normalizedPhysicalControllerComboTarget(part)
            guard !normalized.isEmpty else { return nil }
            tokens.append(normalized)
        }

        guard tokens.contains(where: { !$0.hasSuffix("MS") }) else { return nil }
        return tokens
    }

    @objc public func addCommand(_ command: RemoteCommand) -> Bool {
        command.cmdString = command.cmdString.uppercased() // convert all letters to upper case
        if(command.alias.trimmingCharacters(in: .whitespacesAndNewlines).count == 0) {command.alias = command.cmdString} // copy cmd string as alias when alias is empty
        let keyStrings = extractKeyStringsFromComboCommand(from: command.cmdString)
        if (keyStrings == nil) {return false}  // in case of non-keyboard command strings, return false
        commands.append(command)
        saveCommands()
        viewController?.reloadTableView() // don't know why but this reload has to be called from the CommandManager, doesn't work by calling it in the viewcontroller, probably related with the dialog box.
        return true
    }
    
    @objc public func deleteCommand(at index: Int) {
        guard index >= 0 && index < commands.count else {
            return
        }
        commands.remove(at: index)
        saveCommands()
    }
    
    @objc public func getAllCommands() -> [RemoteCommand] {
        return commands
    }
    
    private func loadCommands() {
        if let savedCommandsData = UserDefaults.standard.data(forKey: "savedCommands") {
            do {
                // Attempt to unarchive the data into an array of RemoteCommand
                if let savedCommands = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, RemoteCommand.self], from: savedCommandsData) as? [RemoteCommand] {
                    // Assign the unarchived commands to your property
                    print(" Assign the unarchived commands to your property ")
                    commands = savedCommands
                } else {
                    // Handle the case where the data could not be unarchived into the expected type
                    print("Data could not be unarchived into [RemoteCommand]")
                }
            } catch {
                // Handle any errors that occur during unarchiving
                print("Failed to unarchive savedCommands with error: \(error)")
            }
        }
    }
    
    
    private func saveCommands() {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: commands, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "savedCommands")
        }
    }

    @objc public func moveCommand(fromIndex: Int, toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < commands.count,
              toIndex >= 0, toIndex < commands.count else { return }
        let moved = commands.remove(at: fromIndex)
        commands.insert(moved, at: toIndex)
        saveCommands()
        viewController?.reloadTableView()
    }
    
    @objc public func sendKeyComboCommand(keyboardCmdStrings: [String], delay: TimeInterval = 0.2, index: Int = 0) { // we need a large delay for WAN streaming
        // 如果已处理完所有按键，则开始释放按键
        guard index < keyboardCmdStrings.count else {
            // 释放按键
            for keyStr in keyboardCmdStrings.reversed() { // 从后往前释放按键
                if let keyCode = CommandManager.keyboardButtonMappings[keyStr] {
                    LiSendKeyboardEvent(keyCode, Int8(KEY_ACTION_UP), 0)  // 释放按键
                }
            }
            return
        }
         
        // 获取当前按键的映射值
        if let keyCode = CommandManager.keyboardButtonMappings[keyboardCmdStrings[index]] {
            // 发送当前按键的按下事件
            LiSendKeyboardEvent(keyCode, Int8(KEY_ACTION_DOWN), 0)

            // 延迟后递归处理下一个按键
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.sendKeyComboCommand(keyboardCmdStrings: keyboardCmdStrings, delay: delay, index: index + 1)
            }
        } else {
            print("No mapping found for \(keyboardCmdStrings[index])")
            // 如果当前按键没有映射，跳过当前按键并继续下一个
            self.sendKeyComboCommand(keyboardCmdStrings: keyboardCmdStrings, delay: delay, index: index + 1)
        }
    }
    
    @objc public func sendKeyComboDown(keyboardCmdStrings: [String]) { // we need a large delay for WAN streaming
        for keyStr in keyboardCmdStrings {
            if let keyCode = CommandManager.keyboardButtonMappings[keyStr] {
                LiSendKeyboardEvent(keyCode, Int8(KEY_ACTION_DOWN), 0)  // 释放按键
            }
        }
    }
    
    @objc public func sendKeyComboUp(keyboardCmdStrings: [String]) { // we need a large delay for WAN streaming
        for keyStr in keyboardCmdStrings {
            if let keyCode = CommandManager.keyboardButtonMappings[keyStr] {
                LiSendKeyboardEvent(keyCode, Int8(KEY_ACTION_UP), 0)  // 释放按键
            }
        }
        return
    }
    
    
}
