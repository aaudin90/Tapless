import AppKit
import Combine

// MARK: - Модель окна

struct VariantState: Identifiable, Equatable {
    enum Status: Equatable {
        case running
        case done(String)
        case failed(String)
    }

    /// Прежняя версия строки: к ней можно откатиться после правки.
    struct Version: Equatable {
        let text: String
        let seconds: Double?
    }

    let id: Int          // клавиша варианта: 1…9
    var name: String
    var status: Status
    var seconds: Double?
    /// Версии до правок, от исходной к последней. Пусто — строку не правили.
    var history: [Version] = []

    var text: String? {
        if case .done(let t) = status { return t }
        return nil
    }
}

/// Высота текста строки: целиком и в пределах `maxLines`.
struct TextHeights: Equatable {
    let full: CGFloat
    let limited: CGFloat

    var isTruncated: Bool { full > limited + 0.5 }
}

@MainActor
final class PopupModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case recording
        case transcribing
        case results
        case message(String)
    }

    /// Запись замечания в режиме правки.
    enum FeedbackPhase: Equatable {
        case idle
        case recording
        case transcribing
        /// ИИ исправляет надиктованное замечание (`llm.feedback_prompt`).
        case polishing
    }

    @Published var phase: Phase = .hidden
    @Published var recordStart = Date()
    @Published var levels: [Float] = Array(repeating: 0, count: 32)
    @Published var rawText = ""
    @Published var variants: [VariantState] = []
    @Published var pendingKey: Int?
    @Published var targetName = ""
    @Published var targetIcon: NSImage?
    @Published var note: String?            // строка-подсказка внизу (статус модели, ошибки)
    @Published var hotkeyDisplay = ""

    /// Правка: клавиша строки, которую правят; nil — режима правки нет.
    @Published var editingKey: Int?
    /// Замечания автора в поле правки.
    @Published var feedback = ""
    @Published var feedbackPhase: FeedbackPhase = .idle
    /// Правка сырого текста. nil — показывается `rawText` как есть; `rawText` остаётся
    /// исходной расшифровкой и уходит в правки как `{text}`.
    @Published var rawRevision: VariantState.Status?
    /// Тексты сырой строки до правок, от исходной расшифровки к последней.
    @Published var rawHistory: [String] = []

    /// Строка, развёрнутая целиком; nil — все строки обрезаны до `maxLines`.
    @Published var expandedKey: Int?
    /// Высоты текста готовых строк по клавише: от них зависит кнопка разворота.
    @Published private(set) var textHeights: [Int: TextHeights] = [:]
    /// Предел высоты развёрнутого текста; длиннее — прокрутка внутри строки.
    @Published var expandedMaxHeight: CGFloat = 400

    /// Клавиша строки «Как распознано» (сырой текст); nil — строки нет.
    var rawKey: Int? = 1
    /// Автовставка (`paste.auto_select`): клавиша и имя строки; nil — выбор цифрой.
    var autoKey: Int?
    var autoName = ""
    var maxLines = 7
    var width: CGFloat = 640

    func pushLevel(_ rms: Float) {
        // RMS → 0…1 по шкале дБ: тишина около −55 дБ, громкая речь около −10 дБ.
        let db = 20 * log10(max(rms, 1e-6))
        let normalized = max(0, min(1, (db + 55) / 45))
        levels.removeFirst()
        levels.append(normalized)
    }

    func resetForRecording() {
        phase = .recording
        recordStart = Date()
        levels = Array(repeating: 0, count: levels.count)
        rawText = ""
        variants = []
        pendingKey = nil
        note = nil
        rawRevision = nil
        rawHistory = []
        expandedKey = nil
        resetEditing()
    }

    /// Пишет только при изменении: `@Published` перерисовывает и на то же значение.
    func setTextHeights(_ heights: [Int: TextHeights]) {
        if textHeights != heights { textHeights = heights }
    }

    /// Текст строки не влез в `maxLines`.
    func isTruncated(_ key: Int) -> Bool {
        textHeights[key]?.isTruncated ?? false
    }

    func resetEditing() {
        editingKey = nil
        feedback = ""
        feedbackPhase = .idle
    }

    /// Автовставка ждёт свою строку: другую цифру не нажимали, вставка не сорвалась.
    var isAutoPending: Bool {
        autoKey != nil && pendingKey == autoKey
    }

    /// Статус строки сырого текста с учётом правки.
    var rawStatus: VariantState.Status {
        if let rawRevision { return rawRevision }
        return rawText.isEmpty ? .running : .done(rawText)
    }
}
