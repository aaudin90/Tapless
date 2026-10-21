import AppKit
import SwiftUI

// MARK: - SwiftUI

struct PopupView: View {
    @ObservedObject var model: PopupModel
    var onSelect: (Int) -> Void
    var onClose: () -> Void
    var onEdit: (Int) -> Void
    var onSubmitEdit: () -> Void
    var onCancelEdit: () -> Void
    var onToggleFeedbackRecording: () -> Void
    var onUndo: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if model.phase == .results || model.phase == .transcribing {
                if let rawKey = model.rawKey {
                    row(key: rawKey,
                        name: "Как распознано" + Self.revisionMark(model.rawHistory.count),
                        status: model.rawStatus,
                        seconds: nil,
                        revisions: model.rawHistory.count,
                        isRaw: true)
                }
                ForEach(model.variants) { variant in
                    row(key: variant.id,
                        name: variant.name + Self.revisionMark(variant.history.count),
                        status: variant.status,
                        seconds: variant.seconds,
                        revisions: variant.history.count,
                        isRaw: false)
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
        .onPreferenceChange(TextHeightsKey.self) { [model] heights in
            MainActor.assumeIsolated { model.setTextHeights(heights) }
        }
    }

    /// Строка варианта, кнопка правки справа и поле замечаний под строкой, если её правят.
    @ViewBuilder
    private func row(key: Int, name: String, status: VariantState.Status, seconds: Double?,
                     revisions: Int, isRaw: Bool) -> some View {
        let isEditing = model.editingKey == key
        let isExpanded = model.expandedKey == key
        HStack(alignment: .top, spacing: 6) {
            Button { onSelect(key) } label: {
                VariantRow(key: key,
                           name: name,
                           status: status,
                           seconds: seconds,
                           isPending: model.pendingKey == key,
                           isRaw: isRaw,
                           maxLines: model.maxLines,
                           isExpanded: isExpanded,
                           fullHeight: model.textHeights[key]?.full,
                           expandedMaxHeight: model.expandedMaxHeight)
            }
            .buttonStyle(VariantRowButtonStyle())

            if model.phase == .results {
                let canAct = model.editingKey == nil && status.isDone
                VStack(spacing: 4) {
                    Button { onEdit(key) } label: {
                        RowIcon(symbol: isEditing ? "pencil.circle.fill" : "pencil",
                                isEnabled: canAct, isActive: isEditing)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAct)
                    .help("Править по замечаниям (⌥\(key))")

                    if revisions > 0 {
                        Button { onUndo(key) } label: {
                            RowIcon(symbol: "arrow.uturn.backward", isEnabled: canAct, isActive: false)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canAct)
                        .help("Вернуть текст до правки (⌥⇧\(key))")
                    }

                    if status.isDone && (isExpanded || model.isTruncated(key)) {
                        Button { model.expandedKey = isExpanded ? nil : key } label: {
                            RowIcon(symbol: isExpanded ? "chevron.up" : "chevron.down",
                                    isEnabled: true, isActive: isExpanded)
                        }
                        .buttonStyle(.plain)
                        .help(isExpanded ? "Свернуть текст" : "Показать текст целиком")
                    }
                }
                .padding(.top, 6)
            }
        }
        if isEditing {
            FeedbackEditor(model: model,
                           onSubmit: onSubmitEdit,
                           onCancel: onCancelEdit,
                           onToggleRecording: onToggleFeedbackRecording)
        }
    }

    /// Пометка в имени строки: «· правка», после нескольких правок — с их числом.
    private static func revisionMark(_ count: Int) -> String {
        switch count {
        case 0: return ""
        case 1: return " · правка"
        default: return " · правка \(count)"
        }
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
                if let key = model.editingKey {
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                    Text("Правка строки \(key): напишите или надиктуйте замечания")
                        .font(.system(size: 14, weight: .semibold))
                } else {
                    Image(systemName: "text.badge.checkmark")
                        .foregroundStyle(.secondary)
                    Text("Выберите вариант").font(.system(size: 14, weight: .semibold))
                }
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
        case .results where model.editingKey != nil:
            var parts = ["↩ — подтвердить", "⇧↩ — новая строка"]
            if !model.hotkeyDisplay.isEmpty { parts.append("\(model.hotkeyDisplay) — надиктовать") }
            parts.append("Esc — отмена правки")
            return parts.joined(separator: " · ")
        case .transcribing, .results:
            let keys = (model.rawKey.map { [$0] } ?? []) + model.variants.map(\.id)
            var parts: [String] = []
            if let first = keys.min(), let last = keys.max() {
                parts.append(first == last ? "\(first) — вставить" : "\(first)–\(last) — вставить")
                parts.append("⇧+цифра — только копировать")
                if model.phase == .results {
                    parts.append("⌥+цифра — править")
                    if !model.rawHistory.isEmpty || model.variants.contains(where: { !$0.history.isEmpty }) {
                        parts.append("⌥⇧+цифра — откатить правку")
                    }
                }
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

private extension VariantState.Status {
    var isDone: Bool {
        if case .done = self { return true }
        return false
    }
}

/// Круглая кнопка справа от строки: правка или откат.
private struct RowIcon: View {
    let symbol: String
    let isEnabled: Bool
    let isActive: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isActive ? Color.accentColor : Color.white.opacity(isEnabled ? 0.75 : 0.25))
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.white.opacity(isEnabled ? 0.08 : 0.03)))
            .contentShape(Circle())
    }
}

/// Поле замечаний к строке: ввод руками или диктовка, «Отмена» и «Подтвердить».
private struct FeedbackEditor: View {
    @ObservedObject var model: PopupModel
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onToggleRecording: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FeedbackTextView(text: model.feedback,
                             isEditable: model.feedbackPhase == .idle,
                             onChange: { model.feedback = $0 },
                             onSubmit: onSubmit)
                .frame(height: 76)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.25))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                )

            HStack(spacing: 8) {
                Button(action: onToggleRecording) {
                    HStack(spacing: 6) {
                        switch model.feedbackPhase {
                        case .idle:
                            Image(systemName: "mic.fill")
                            Text(model.hotkeyDisplay.isEmpty ? "Надиктовать" : "Надиктовать · \(model.hotkeyDisplay)")
                        case .recording:
                            PulsingDot()
                            Text("Стоп")
                            LevelMeter(levels: Array(model.levels.suffix(16)))
                        case .transcribing:
                            ProgressView().controlSize(.mini)
                            Text("Распознаю…")
                        case .polishing:
                            ProgressView().controlSize(.mini)
                            Text("Исправляю…")
                        }
                    }
                }
                .buttonStyle(EditorButtonStyle(prominent: false))
                .disabled(model.feedbackPhase == .transcribing || model.feedbackPhase == .polishing)

                Spacer(minLength: 8)

                Button("Отмена", action: onCancel)
                    .buttonStyle(EditorButtonStyle(prominent: false))
                Button("Подтвердить ↩", action: onSubmit)
                    .buttonStyle(EditorButtonStyle(prominent: true))
                    .disabled(!canSubmit)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var canSubmit: Bool {
        model.feedbackPhase == .idle && !model.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct EditorButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        EditorButton(configuration: configuration, prominent: prominent)
    }
}

private struct EditorButton: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Color.white.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule().fill(prominent ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.10))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

/// Многострочное поле на NSTextView: ↩ — подтвердить, ⇧↩ / ⌥↩ — новая строка.
/// Без `@FocusState` и `@Binding` из SwiftUI: фокус ставим сами через `makeFirstResponder`.
private struct FeedbackTextView: NSViewRepresentable {
    let text: String
    let isEditable: Bool
    let onChange: (String) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = FocusingTextView()
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        textView.delegate = context.coordinator
        scroll.documentView = textView
        context.coordinator.parent = self
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        if textView.string != text {
            // Текст пришёл не из поля (диктовка): курсор — в конец.
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.scrollToEndOfDocument(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FeedbackTextView?

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent?.onChange(textView.string)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent?.onSubmit()
            }
            return true
        }
    }

    /// Берёт фокус, как только появляется в окне.
    final class FocusingTextView: NSTextView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
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
    let isExpanded: Bool
    /// Замеренная высота текста целиком; nil — ещё не замерена.
    let fullHeight: CGFloat?
    let expandedMaxHeight: CGFloat

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
            let styled = Text(text)
                .font(.system(size: isRaw ? 12.5 : 13.5))
                .foregroundStyle(isRaw ? Color.white.opacity(0.65) : Color.white.opacity(0.95))
            Group {
                if !isExpanded {
                    styled
                        .lineLimit(maxLines)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let fullHeight, fullHeight > expandedMaxHeight {
                    ScrollView(.vertical) {
                        styled
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: expandedMaxHeight)
                } else {
                    styled.fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TextHeightsProbe(key: key, text: styled, maxLines: maxLines))
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

/// Высоты текста готовых строк по клавише; собирает их `PopupView` в модель.
private struct TextHeightsKey: PreferenceKey {
    static let defaultValue: [Int: TextHeights] = [:]

    static func reduce(value: inout [Int: TextHeights], nextValue: () -> [Int: TextHeights]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Невидимые копии текста строки шириной с саму строку: целиком и в пределах `maxLines`.
/// По ним видно, обрезан ли текст и какой высоты он будет развёрнутым.
private struct TextHeightsProbe: View {
    let key: Int
    let text: Text
    let maxLines: Int

    var body: some View {
        GeometryReader { proxy in
            text
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: proxy.size.width, alignment: .topLeading)
                .background(GeometryReader { full in
                    text
                        .lineLimit(maxLines)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: full.size.width, alignment: .topLeading)
                        .background(GeometryReader { limited in
                            Color.clear.preference(
                                key: TextHeightsKey.self,
                                value: [key: TextHeights(full: full.size.height, limited: limited.size.height)])
                        })
                })
                .hidden()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
