import AppKit
import Carbon.HIToolbox
import TapLessDomain

// Глобальные горячие клавиши через Carbon RegisterEventHotKey:
// не требуют разрешений и умеют ловить и нажатие, и отпускание (для push-to-talk).

struct HotKeySpec: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String
}

enum HotKeyError: LocalizedError {
    case empty
    case unknownKey(String)
    case unknownModifier(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "Горячая клавиша не задана"
        case .unknownKey(let k): return "Неизвестная клавиша «\(k)»"
        case .unknownModifier(let m): return "Неизвестный модификатор «\(m)»"
        }
    }
}

enum HotKeyParser {
    private static let modifierMap: [String: (UInt32, String)] = [
        "cmd": (UInt32(cmdKey), "⌘"), "command": (UInt32(cmdKey), "⌘"), "⌘": (UInt32(cmdKey), "⌘"),
        "ctrl": (UInt32(controlKey), "⌃"), "control": (UInt32(controlKey), "⌃"), "⌃": (UInt32(controlKey), "⌃"),
        "opt": (UInt32(optionKey), "⌥"), "option": (UInt32(optionKey), "⌥"), "alt": (UInt32(optionKey), "⌥"), "⌥": (UInt32(optionKey), "⌥"),
        "shift": (UInt32(shiftKey), "⇧"), "⇧": (UInt32(shiftKey), "⇧"),
    ]

    static let digitKeyCodes: [Int] = [
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
        kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    static let keypadKeyCodes: [Int] = [
        kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
        kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
    ]

    private static let keyMap: [String: (Int, String)] = {
        var map: [String: (Int, String)] = [:]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z),
        ]
        for (name, code) in letters { map[name] = (code, name.uppercased()) }
        for (i, code) in digitKeyCodes.enumerated() { map["\(i)"] = (code, "\(i)") }

        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in fKeys.enumerated() { map["f\(i + 1)"] = (code, "F\(i + 1)") }

        let named: [(String, Int, String)] = [
            ("space", kVK_Space, "Space"), ("return", kVK_Return, "↩"), ("enter", kVK_Return, "↩"),
            ("tab", kVK_Tab, "⇥"), ("escape", kVK_Escape, "⎋"), ("esc", kVK_Escape, "⎋"),
            ("grave", kVK_ANSI_Grave, "`"), ("backtick", kVK_ANSI_Grave, "`"), ("`", kVK_ANSI_Grave, "`"),
            ("section", kVK_ISO_Section, "§"), ("§", kVK_ISO_Section, "§"),
            ("minus", kVK_ANSI_Minus, "-"), ("equal", kVK_ANSI_Equal, "="),
            ("comma", kVK_ANSI_Comma, ","), ("period", kVK_ANSI_Period, "."),
            ("slash", kVK_ANSI_Slash, "/"), ("backslash", kVK_ANSI_Backslash, "\\"),
            ("semicolon", kVK_ANSI_Semicolon, ";"), ("quote", kVK_ANSI_Quote, "'"),
            ("leftbracket", kVK_ANSI_LeftBracket, "["), ("rightbracket", kVK_ANSI_RightBracket, "]"),
        ]
        for (name, code, display) in named { map[name] = (code, display) }
        return map
    }()

    static func parse(_ string: String) throws -> HotKeySpec {
        let parts = string.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyName = parts.last else { throw HotKeyError.empty }

        var modifiers: UInt32 = 0
        var display = ""
        // Порядок значков как в macOS: ⌃⌥⇧⌘
        var symbols = Set<String>()
        for part in parts.dropLast() {
            guard let (mask, symbol) = modifierMap[part] else { throw HotKeyError.unknownModifier(part) }
            modifiers |= mask
            symbols.insert(symbol)
        }
        for symbol in ["⌃", "⌥", "⇧", "⌘"] where symbols.contains(symbol) { display += symbol }

        guard let (code, keyDisplay) = keyMap[keyName] else { throw HotKeyError.unknownKey(keyName) }
        return HotKeySpec(keyCode: UInt32(code), modifiers: modifiers, display: display + keyDisplay)
    }
}

/// Регистр горячих клавиш. Колбэки вызываются на главном потоке.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Entry {
        let ref: EventHotKeyRef
        let onPress: @MainActor () -> Void
        let onRelease: (@MainActor () -> Void)?
    }

    private var entries: [UInt32: Entry] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?

    private init() {
        let specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(GetEventDispatcherTarget(), tapLessHotKeyHandler, 2, specs, nil, &handlerRef)
        if status != noErr {
            Log.error("InstallEventHandler: \(status)", .hotkey)
        }
    }

    /// Возвращает id для unregister или nil, если комбинация занята.
    func register(keyCode: UInt32, modifiers: UInt32,
                  onPress: @escaping @MainActor () -> Void,
                  onRelease: (@MainActor () -> Void)? = nil) -> UInt32? {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5450_4C53) /* 'TPLS' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.error("RegisterEventHotKey(keyCode=\(keyCode), modifiers=\(modifiers)) → \(status)", .hotkey)
            return nil
        }
        entries[id] = Entry(ref: ref, onPress: onPress, onRelease: onRelease)
        Log.debug("Клавиша зарегистрирована: id=\(id), keyCode=\(keyCode), modifiers=\(modifiers)", .hotkey)
        return id
    }

    func register(_ spec: HotKeySpec,
                  onPress: @escaping @MainActor () -> Void,
                  onRelease: (@MainActor () -> Void)? = nil) -> UInt32? {
        register(keyCode: spec.keyCode, modifiers: spec.modifiers, onPress: onPress, onRelease: onRelease)
    }

    func unregister(_ id: UInt32) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(entry.ref)
        Log.debug("Клавиша снята: id=\(id)", .hotkey)
    }

    func unregister(_ ids: [UInt32]) {
        guard !ids.isEmpty else { return }
        Log.debug("Снимаю клавиш: \(ids.count)", .hotkey)
        ids.forEach { unregister($0) }
    }

    fileprivate func dispatch(id: UInt32, pressed: Bool) {
        guard let entry = entries[id] else { return }
        if pressed {
            entry.onPress()
        } else {
            entry.onRelease?()
        }
    }
}

/// C-обработчик Carbon-событий. Вызывается на главном потоке.
private func tapLessHotKeyHandler(_ next: EventHandlerCallRef?,
                                   _ event: EventRef?,
                                   _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let id = hotKeyID.id
    // Отдаём в следующий проход run loop: обработчик может сам снимать/вешать клавиши.
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            HotKeyCenter.shared.dispatch(id: id, pressed: pressed)
        }
    }
    return noErr
}
