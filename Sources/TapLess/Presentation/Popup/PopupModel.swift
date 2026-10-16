import AppKit
import Combine

// MARK: - Модель окна

struct VariantState: Identifiable, Equatable {
    enum Status: Equatable {
        case running
        case done(String)
        case failed(String)
    }

    let id: Int          // клавиша варианта: 1…9
    var name: String
    var status: Status
    var seconds: Double?

    var text: String? {
        if case .done(let t) = status { return t }
        return nil
    }
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

    /// Клавиша строки «Как распознано» (сырой текст); nil — строки нет.
    var rawKey: Int? = 1
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
    }
}
