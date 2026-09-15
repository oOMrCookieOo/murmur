import CoreGraphics
import Carbon.HIToolbox
import IOKit.hidsystem

/// A modifier key usable as the push-to-talk trigger.
///
/// Every case is a *modifier*, deliberately: modifiers produce `.flagsChanged`
/// events that carry a device-dependent left/right bit, so we can distinguish
/// Right Option from Left Option. Regular keys would be swallowed from whatever
/// app is focused, which is unacceptable for a key you hold down constantly.
enum TriggerKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case rightOption
    case leftOption
    case rightCommand
    case rightControl
    case rightShift
    case fn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightOption:  return "Right Option (⌥)"
        case .leftOption:   return "Left Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .rightShift:   return "Right Shift (⇧)"
        case .fn:           return "Fn / Globe (🌐)"
        }
    }

    /// Virtual key code reported in the `.keyboardEventKeycode` field of a
    /// `.flagsChanged` event.
    var keyCode: Int64 {
        switch self {
        case .rightOption:  return Int64(kVK_RightOption)   // 61
        case .leftOption:   return Int64(kVK_Option)        // 58
        case .rightCommand: return Int64(kVK_RightCommand)  // 54
        case .rightControl: return Int64(kVK_RightControl)  // 62
        case .rightShift:   return Int64(kVK_RightShift)    // 60
        case .fn:           return Int64(kVK_Function)      // 63
        }
    }

    /// Bit in `CGEventFlags` that is set while this specific physical key is held.
    ///
    /// The `NX_DEVICE*` masks are the device-dependent modifier bits; they are
    /// what makes left/right discrimination possible. Fn has no device-dependent
    /// bit and uses the ordinary secondary-Fn mask instead.
    var flagMask: UInt64 {
        switch self {
        case .rightOption:  return UInt64(NX_DEVICERALTKEYMASK)    // 0x40
        case .leftOption:   return UInt64(NX_DEVICELALTKEYMASK)    // 0x20
        case .rightCommand: return UInt64(NX_DEVICERCMDKEYMASK)    // 0x10
        case .rightControl: return UInt64(NX_DEVICERCTLKEYMASK)    // 0x2000
        case .rightShift:   return UInt64(NX_DEVICERSHIFTKEYMASK)  // 0x04
        case .fn:           return CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    /// True when this key is physically down, according to `flags`.
    func isHeld(in flags: CGEventFlags) -> Bool {
        (flags.rawValue & flagMask) == flagMask
    }
}
