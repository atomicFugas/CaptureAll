import AppKit
import Carbon.HIToolbox

struct KeyChord: Equatable, Hashable, Codable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    var displayString: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    var storageString: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("cmd") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("shift") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("option") }
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("control") }
        parts.append(Self.keyToken(for: keyCode))
        return parts.joined(separator: "+")
    }

    /// Single-character keyEquivalent for `NSMenuItem` (empty if unsupported).
    var menuKeyEquivalent: String {
        let token = Self.keyToken(for: keyCode)
        switch token {
        case "space": return " "
        case "return", "enter", "escape": return ""
        default:
            return token.count == 1 ? token : ""
        }
    }

    var menuKeyEquivalentModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    static func parse(_ string: String) -> KeyChord? {
        let tokens = string.lowercased().split(separator: "+").map(String.init)
        guard let keyToken = tokens.last else { return nil }
        var mods: UInt32 = 0
        for t in tokens.dropLast() {
            switch t {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "shift": mods |= UInt32(shiftKey)
            case "option", "alt", "opt": mods |= UInt32(optionKey)
            case "control", "ctrl": mods |= UInt32(controlKey)
            default: break
            }
        }
        guard let code = keyCode(for: keyToken) else { return nil }
        return KeyChord(keyCode: code, carbonModifiers: mods)
    }

    static func from(event: NSEvent) -> KeyChord? {
        let mods = carbonMods(from: event.modifierFlags)
        // Require at least one modifier for global chord matching.
        guard mods != 0 else { return nil }
        return KeyChord(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
    }

    static func carbonMods(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    private static func keyCode(for token: String) -> UInt32? {
        switch token {
        case "a": return UInt32(kVK_ANSI_A)
        case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C)
        case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E)
        case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G)
        case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I)
        case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K)
        case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M)
        case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O)
        case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q)
        case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S)
        case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U)
        case "v": return UInt32(kVK_ANSI_V)
        case "w": return UInt32(kVK_ANSI_W)
        case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y)
        case "z": return UInt32(kVK_ANSI_Z)
        case "0": return UInt32(kVK_ANSI_0)
        case "1": return UInt32(kVK_ANSI_1)
        case "2": return UInt32(kVK_ANSI_2)
        case "3": return UInt32(kVK_ANSI_3)
        case "4": return UInt32(kVK_ANSI_4)
        case "5": return UInt32(kVK_ANSI_5)
        case "6": return UInt32(kVK_ANSI_6)
        case "7": return UInt32(kVK_ANSI_7)
        case "8": return UInt32(kVK_ANSI_8)
        case "9": return UInt32(kVK_ANSI_9)
        case "space": return UInt32(kVK_Space)
        case "return", "enter": return UInt32(kVK_Return)
        case "escape", "esc": return UInt32(kVK_Escape)
        default: return nil
        }
    }

    private static func keyToken(for code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_A: return "a"
        case kVK_ANSI_B: return "b"
        case kVK_ANSI_C: return "c"
        case kVK_ANSI_D: return "d"
        case kVK_ANSI_E: return "e"
        case kVK_ANSI_F: return "f"
        case kVK_ANSI_G: return "g"
        case kVK_ANSI_H: return "h"
        case kVK_ANSI_I: return "i"
        case kVK_ANSI_J: return "j"
        case kVK_ANSI_K: return "k"
        case kVK_ANSI_L: return "l"
        case kVK_ANSI_M: return "m"
        case kVK_ANSI_N: return "n"
        case kVK_ANSI_O: return "o"
        case kVK_ANSI_P: return "p"
        case kVK_ANSI_Q: return "q"
        case kVK_ANSI_R: return "r"
        case kVK_ANSI_S: return "s"
        case kVK_ANSI_T: return "t"
        case kVK_ANSI_U: return "u"
        case kVK_ANSI_V: return "v"
        case kVK_ANSI_W: return "w"
        case kVK_ANSI_X: return "x"
        case kVK_ANSI_Y: return "y"
        case kVK_ANSI_Z: return "z"
        case kVK_Space: return "space"
        case kVK_Return: return "return"
        case kVK_Escape: return "escape"
        default: return "key\(code)"
        }
    }

    private static func keyName(for code: UInt32) -> String {
        keyToken(for: code).uppercased()
    }
}
