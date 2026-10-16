import AppKit
import ApplicationServices
import Carbon.HIToolbox
import TapLessDomain

/// Вставка текста в окно, которое было в фокусе: буфер обмена + ⌘V.
@MainActor
enum Paster {
    enum Outcome {
        case pasted
        case copied
        case copiedNeedsAccessibility
    }

    /// Пометка для менеджеров буфера (Maccy, Raycast, Paste): «не сохранять в историю».
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос на «Универсальный доступ», если его ещё нет.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func deliver(_ text: String,
                        to target: NSRunningApplication?,
                        config: PasteConfig,
                        copyOnly: Bool) async -> Outcome {
        let pasteboard = NSPasteboard.general
        let willPaste = !copyOnly && config.autoPaste && isTrusted
        let snapshot = (willPaste && config.restoreClipboard) ? takeSnapshot(pasteboard) : nil
        Log.info("Вставка: copyOnly=\(copyOnly), auto_paste=\(config.autoPaste), «Универсальный доступ»=\(isTrusted ? "есть" : "нет"), цель=\(target?.bundleIdentifier ?? "—")", .paste)
        if let snapshot {
            Log.debug("Снимок буфера: \(snapshot.count) эл.", .paste)
        }

        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if snapshot != nil {
            item.setData(Data(), forType: transientType)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let ourChangeCount = pasteboard.changeCount

        if copyOnly || !config.autoPaste {
            Log.info("Текст скопирован в буфер без вставки", .paste)
            return .copied
        }
        guard willPaste else {
            Log.warning("Текст скопирован, но вставить нельзя: нет доступа «Универсальный доступ»", .paste)
            return .copiedNeedsAccessibility
        }

        if let target, !target.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            Log.debug("Активирую целевое приложение \(target.bundleIdentifier ?? "?")", .paste)
            target.activate(options: [])
        }

        try? await Task.sleep(nanoseconds: UInt64(max(0, config.pasteDelayMs)) * 1_000_000)
        postCommandV()
        Log.info("⌘V отправлен", .paste)

        if let snapshot {
            try? await Task.sleep(nanoseconds: UInt64(max(0, config.restoreDelayMs)) * 1_000_000)
            // Если за это время буфер поменял кто-то другой — не трогаем.
            if pasteboard.changeCount == ourChangeCount {
                restore(snapshot, to: pasteboard)
                Log.info("Буфер обмена восстановлен", .paste)
            } else {
                Log.info("Буфер обмена изменился во время вставки — восстановление пропущено", .paste)
            }
        }
        return .pasted
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private static func takeSnapshot(_ pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
