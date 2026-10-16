import AppKit
import Combine
import SwiftUI
import TapLessDomain

// MARK: - Окно

/// Плавающая панель, которая не забирает фокус у текущего приложения.
@MainActor
final class PopupController {
    private let model: PopupModel
    private var panel: NSPanel?
    private var hostingView: FirstMouseHostingView<PopupView>?
    private var cancellable: AnyCancellable?
    // Верхний край и центр окна. Размер меняется под содержимое, а якорь — только
    // при показе окна или когда его перетащили мышью.
    private var anchorTop: CGFloat = 0
    private var anchorMidX: CGFloat = 0
    private var isSettingFrame = false

    var position = "top"
    var onSelect: (Int) -> Void = { _ in }
    var onClose: () -> Void = {}

    init(model: PopupModel) {
        self.model = model
        // Небольшая задержка: SwiftUI должен успеть применить изменения до замера fittingSize.
        cancellable = model.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated { self.relayout() }
            }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible { computeAnchor() }
        relayout()
        panel.orderFrontRegardless()
        Log.debug("Панель показана (позиция \(position))", .ui)
    }

    func hide() {
        if isVisible { Log.debug("Панель скрыта", .ui) }
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: model.width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)

        let view = PopupView(
            model: model,
            onSelect: { [weak self] key in self?.onSelect(key) },
            onClose: { [weak self] in self?.onClose() }
        )
        let host = FirstMouseHostingView(rootView: view)
        panel.contentView = host
        hostingView = host

        // queue: nil — обработчик вызывается синхронно (на главном потоке, где двигают окно),
        // поэтому флаг isSettingFrame отличает наши setFrame от перетаскивания мышью.
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: nil) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                // Окно перетащили мышью — запоминаем новое место.
                guard !self.isSettingFrame, let frame = self.panel?.frame else { return }
                self.anchorTop = frame.maxY
                self.anchorMidX = frame.midX
            }
        }
        center.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: nil) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard !self.isSettingFrame else { return }
                self.relayout()
            }
        }
        return panel
    }

    private func computeAnchor() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        anchorMidX = frame.midX
        if position.lowercased() == "center" {
            anchorTop = frame.midY + frame.height * 0.2
        } else {
            anchorTop = frame.maxY - 48
        }
    }

    private func relayout() {
        guard let panel, let hostingView else { return }
        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        var frame = NSRect(x: (anchorMidX - size.width / 2).rounded(),
                           y: (anchorTop - size.height).rounded(),
                           width: size.width,
                           height: size.height)
        // Не даём окну уйти за нижний край экрана, если вариантов много и они длинные.
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchorMidX, y: anchorTop - 1)) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame, frame.minY < visible.minY + 8 {
            frame.origin.y = visible.minY + 8
        }

        if frame != panel.frame {
            isSettingFrame = true
            panel.setFrame(frame, display: true)
            isSettingFrame = false
        }
    }
}

/// Клик по строке срабатывает сразу, даже если панель не активна.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
