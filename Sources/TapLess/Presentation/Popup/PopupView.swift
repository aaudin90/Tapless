import AppKit
import SwiftUI

// MARK: - SwiftUI

struct PopupView: View {
    @ObservedObject var model: PopupModel
    var onSelect: (Int) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if model.phase == .results || model.phase == .transcribing {
                if let rawKey = model.rawKey {
                    Button { onSelect(rawKey) } label: {
                        VariantRow(key: rawKey,
                                   name: "Как распознано",
                                   status: model.rawText.isEmpty ? .running : .done(model.rawText),
                                   seconds: nil,
                                   isPending: model.pendingKey == rawKey,
                                   isRaw: true,
                                   maxLines: model.maxLines)
                    }
                    .buttonStyle(VariantRowButtonStyle())
                }
                ForEach(model.variants) { variant in
                    Button { onSelect(variant.id) } label: {
                        VariantRow(key: variant.id,
                                   name: variant.name,
                                   status: variant.status,
                                   seconds: variant.seconds,
                                   isPending: model.pendingKey == variant.id,
                                   isRaw: false,
                                   maxLines: model.maxLines)
                    }
                    .buttonStyle(VariantRowButtonStyle())
                }
            }

            footer
        }
        .padding(14)
        .frame(width: model.width, alignment: .leading)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .recording:
                PulsingDot()
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    Text("Слушаю · \(Self.format(context.date.timeIntervalSince(model.recordStart)))")
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                LevelMeter(levels: model.levels)
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Распознаю…").font(.system(size: 14, weight: .semibold))
                Spacer()
            case .results:
                Image(systemName: "text.badge.checkmark")
                    .foregroundStyle(.secondary)
                Text("Выберите вариант").font(.system(size: 14, weight: .semibold))
                Spacer()
            case .message(let text):
                Image(systemName: "exclamationmark.bubble")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            case .hidden:
                EmptyView()
            }
            if model.phase != .hidden {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = model.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 6) {
                Text(hintText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !model.targetName.isEmpty {
                    if let icon = model.targetIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 14, height: 14)
                    }
                    Text("→ \(model.targetName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var hintText: String {
        switch model.phase {
        case .recording:
            return model.hotkeyDisplay.isEmpty ? "Esc — отмена" : "\(model.hotkeyDisplay) — стоп · Esc — отмена"
        case .transcribing, .results:
            let keys = (model.rawKey.map { [$0] } ?? []) + model.variants.map(\.id)
            var parts: [String] = []
            if let first = keys.min(), let last = keys.max() {
                parts.append(first == last ? "\(first) — вставить" : "\(first)–\(last) — вставить")
                parts.append("⇧+цифра — только копировать")
            }
            parts.append("Esc — закрыть")
            return parts.joined(separator: " · ")
        case .message:
            return "Esc — закрыть"
        case .hidden:
            return ""
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct VariantRow: View {
    let key: Int
    let name: String
    let status: VariantState.Status
    let seconds: Double?
    let isPending: Bool
    let isRaw: Bool
    let maxLines: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(key)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(badgeColor)
                )
                .foregroundStyle(isReady ? Color.black : Color.white.opacity(0.7))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer(minLength: 4)
                    statusAccessory
                }
                bodyText
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isPending ? Color.accentColor.opacity(0.28) : Color.white.opacity(isRaw ? 0.03 : 0.06))
        )
        .contentShape(Rectangle())
    }

    private var isReady: Bool {
        if case .done = status { return true }
        return false
    }

    private var badgeColor: Color {
        switch status {
        case .done: return isRaw ? Color.white.opacity(0.75) : Color.accentColor.opacity(0.95)
        case .running: return Color.white.opacity(0.10)
        case .failed: return Color.red.opacity(0.35)
        }
    }

    @ViewBuilder
    private var statusAccessory: some View {
        switch status {
        case .running:
            if isPending {
                Text("вставлю, когда будет готово")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ProgressView().controlSize(.mini)
        case .done:
            if let seconds {
                Text(String(format: "%.1f с", seconds))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var bodyText: some View {
        switch status {
        case .running:
            Text(isRaw ? "…" : "думаю…")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        case .done(let text):
            Text(text)
                .font(.system(size: isRaw ? 12.5 : 13.5))
                .foregroundStyle(isRaw ? Color.white.opacity(0.65) : Color.white.opacity(0.95))
                .lineLimit(maxLines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.red.opacity(0.85))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Строка варианта как кнопка: подсветка под курсором, при нажатии — сжатие и вспышка.
private struct VariantRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        VariantRowButton(configuration: configuration)
    }
}

// Без @State: в новых SDK это макрос, а плагина SwiftUIMacros нет в Command Line Tools.
private final class HoverState: ObservableObject {
    @Published private(set) var isHovered = false

    /// Пишет только при изменении: `@Published` перерисовывает и на то же значение.
    func set(_ value: Bool) {
        if isHovered != value { isHovered = value }
    }
}

private struct VariantRowButton: View {
    let configuration: ButtonStyleConfiguration
    @StateObject private var hover = HoverState()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .overlay(shape.fill(Color.white.opacity(configuration.isPressed ? 0.12 : hover.isHovered ? 0.06 : 0)))
            .overlay(shape.strokeBorder(Color.white.opacity(hover.isHovered ? 0.22 : 0), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: hover.isHovered)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: configuration.isPressed)
            .background(HoverTracker { hover.set($0) })
            .accessibilityElement(children: .combine)
    }
}

/// Наведение мыши через свой NSTrackingArea с `.activeAlways`: панель не забирает фокус,
/// TapLess не активное приложение, а `onHover` в таком окне срабатывает не всегда.
private struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void = { _ in }

        // С .inVisibleRect AppKit сам следит за размером: область создаётся один раз.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard trackingAreas.isEmpty else { return }
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
        // Панель прячут (`orderOut`) и показывают снова, не пересоздавая строки, а
        // mouseEntered / mouseExited при этом не приходят: сверяем курсор сами.
        private var visibilityObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            visibilityObserver.map(NotificationCenter.default.removeObserver)
            visibilityObserver = nil
            guard let window else { onChange(false); return }
            visibilityObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.syncWithMouse() }
            // Строка могла появиться прямо под курсором (распознавание → результаты).
            // Асинхронно: сейчас идёт обновление SwiftUI, менять состояние в нём нельзя.
            DispatchQueue.main.async { [weak self] in self?.syncWithMouse() }
        }

        private func syncWithMouse() {
            guard let window, window.occlusionState.contains(.visible) else { onChange(false); return }
            onChange(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        }

        deinit {
            visibilityObserver.map(NotificationCenter.default.removeObserver)
        }
        // Клики проходят к кнопке.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.white.opacity(0.35 + Double(level) * 0.6))
                    .frame(width: 3, height: 3 + CGFloat(level) * 19)
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

// Без @State: в новых SDK это макрос, а плагина SwiftUIMacros нет в Command Line Tools.
private struct PulsingDot: View {
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .phaseAnimator([0.35, 1.0]) { content, opacity in
                content.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.6)
            }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
