import Foundation

/// Значение `general.voice_processing`: нужна ли записи своя голосовая обработка Apple (VPIO).
/// Пока звонилка держит голосовую обработку, встроенный микрофон отдаёт 3 сырых канала
/// в 100–200 раз тише обычного, и VPIO даёт обработанный сигнал (шумоподавление, AGC) вместо усиления ×100.
public enum VoiceProcessingMode: Sendable, Equatable {
    /// Без VPIO: сырой вход звонка усредняется и усиливается по громкости речи (`SpeechGain`).
    case off
    /// VPIO включается, только когда вход похож на звонок (`isCallInput`): встроенный микрофон и не меньше 3 каналов.
    case call

    public static let offValue = "off"
    public static let callValue = "call"

    /// Неизвестное значение — `off` (его же отмечает `AppConfig.validationWarnings`).
    public init(_ raw: String) {
        self = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.callValue ? .call : .off
    }

    /// Значение распознаётся: `off` или `call` без учёта регистра и пробелов по краям.
    public static func isValid(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == offValue || value == callValue
    }

    public var rawValue: String {
        self == .call ? Self.callValue : Self.offValue
    }

    /// Сколько каналов отдаёт встроенный микрофон, пока звонилка держит голосовую обработку.
    public static let callInputChannels = 3

    /// Похож ли вход на звонок: устройство встроенное (`AudioTransport.builtIn`) и каналов не меньше
    /// `callInputChannels`. Только такой вход получает VPIO и усиление ×100: USB-стерео, звуковые карты
    /// и виртуальные устройства (BlackHole) тоже многоканальные, но они отдают обычный сигнал.
    public static func isCallInput(inputChannels: Int, isBuiltIn: Bool) -> Bool {
        isBuiltIn && inputChannels >= callInputChannels
    }

    /// Включать ли VPIO для входа с таким числом каналов и такого устройства.
    public func shouldEnable(inputChannels: Int, isBuiltIn: Bool) -> Bool {
        self == .call && Self.isCallInput(inputChannels: inputChannels, isBuiltIn: isBuiltIn)
    }
}
