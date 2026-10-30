import Foundation

/// Тип подключения аудиоустройства (по `kAudioDevicePropertyTransportType`).
public enum AudioTransport: Sendable, Equatable {
    case builtIn
    /// Bluetooth Classic и Bluetooth LE.
    case bluetooth
    /// Внешнее проводное: USB, Thunderbolt, FireWire, PCI, AVB, DisplayPort, HDMI.
    case wired
    /// Виртуальное и агрегатное устройство (BlackHole, Loopback, «Агрегатное устройство»).
    case virtual
    /// Остальное и неизвестное.
    case other
}

/// Устройство CoreAudio в том виде, который нужен выбору микрофона.
public struct AudioInputDevice: Sendable, Equatable {
    public var id: UInt32
    /// `kAudioDevicePropertyDeviceUID`: стабильный между перезапусками и подключениями.
    public var uid: String
    public var name: String
    public var transport: AudioTransport
    /// `kAudioDevicePropertyDeviceIsAlive`.
    public var isAlive: Bool
    /// Есть входные каналы (`kAudioDevicePropertyStreamConfiguration`, scope input).
    public var hasInput: Bool
    /// `kAudioDevicePropertyNominalSampleRate`, Гц; 0 — неизвестна.
    public var nominalSampleRate: Double

    public init(id: UInt32, uid: String, name: String, transport: AudioTransport, isAlive: Bool,
                hasInput: Bool, nominalSampleRate: Double) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.isAlive = isAlive
        self.hasInput = hasInput
        self.nominalSampleRate = nominalSampleRate
    }

    /// Живое устройство с входными каналами.
    public var isUsableInput: Bool { isAlive && hasInput }
}

/// Значение `general.microphone`.
public enum MicrophoneSetting: Sendable, Equatable {
    /// Системное устройство, если это не Bluetooth; иначе лучшее не-Bluetooth.
    case auto
    /// Всегда устройство ввода по умолчанию.
    case system
    /// Конкретный микрофон: UID или имя.
    case device(String)

    public static let autoValue = "auto"
    public static let systemValue = "system"

    /// Пустая строка — как `"auto"`. Регистр и пробелы в `auto` / `system` не важны.
    public init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "", Self.autoValue: self = .auto
        case Self.systemValue: self = .system
        default: self = .device(trimmed)
        }
    }

    /// Что писать в файл: `auto`, `system` или UID/имя устройства.
    public var rawValue: String {
        switch self {
        case .auto: return Self.autoValue
        case .system: return Self.systemValue
        case .device(let id): return id
        }
    }
}

/// Результат выбора микрофона.
public struct InputDeviceChoice: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// Устройство ввода по умолчанию неизвестно.
        case noDefault
        /// `"system"`.
        case systemRequested
        /// `"auto"`: по умолчанию не Bluetooth — оно и остаётся.
        case defaultKept
        /// `"auto"`: по умолчанию Bluetooth, а живого проводного или встроенного входа нет.
        case noAlternative
        /// `"auto"`: Bluetooth-устройство по умолчанию заменено другим.
        case replacedBluetooth(replacing: UInt32)
        /// Конкретный микрофон из настройки.
        case explicit
    }

    /// Устройство для привязки; nil — оставить устройство ввода по умолчанию.
    public var deviceID: UInt32?
    public var reason: Reason
    /// Настройка просила конкретный микрофон, но он не найден или не живой (тогда выбор сделан как для `"auto"`).
    public var unavailableRequest: String?

    public init(deviceID: UInt32?, reason: Reason, unavailableRequest: String? = nil) {
        self.deviceID = deviceID
        self.reason = reason
        self.unavailableRequest = unavailableRequest
    }
}

/// Выбор микрофона. Запись с Bluetooth-гарнитуры переводит её в профиль HFP (узкая полоса, моно),
/// и звук в наушниках у всех программ становится глухим. Чтобы этого избежать, выбор идёт по
/// статическим свойствам устройств: открывать микрофон ради замера уровня нельзя, это и есть переключение профиля.
public enum InputDeviceSelection {
    /// - Parameters:
    ///   - devices: все известные устройства.
    ///   - defaultInput: id устройства ввода по умолчанию.
    ///   - setting: `general.microphone`.
    public static func choose(devices: [AudioInputDevice], defaultInput: UInt32?, setting: MicrophoneSetting) -> InputDeviceChoice {
        var unavailable: String?
        switch setting {
        case .system:
            return InputDeviceChoice(deviceID: nil, reason: .systemRequested)
        case .device(let wanted):
            if let device = find(wanted, in: devices) {
                return InputDeviceChoice(deviceID: device.id, reason: .explicit)
            }
            unavailable = wanted
        case .auto:
            break
        }
        var choice = automatic(devices: devices, defaultInput: defaultInput)
        choice.unavailableRequest = unavailable
        return choice
    }

    /// Сначала по UID, потом по имени (без учёта регистра); только живые устройства с входом.
    private static func find(_ wanted: String, in devices: [AudioInputDevice]) -> AudioInputDevice? {
        let usable = devices.filter(\.isUsableInput)
        return usable.first { $0.uid == wanted }
            ?? usable.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    private static func automatic(devices: [AudioInputDevice], defaultInput: UInt32?) -> InputDeviceChoice {
        guard let defaultInput else { return InputDeviceChoice(deviceID: nil, reason: .noDefault) }
        guard let current = devices.first(where: { $0.id == defaultInput }), current.transport == .bluetooth else {
            return InputDeviceChoice(deviceID: nil, reason: .defaultKept)
        }
        // Проводное важнее встроенного (гарнитура или док-станция лучше микрофона в корпусе);
        // среди равных — с большей частотой; ещё равнее — первое в списке.
        let candidates = devices.filter {
            $0.id != defaultInput && $0.isUsableInput && ($0.transport == .wired || $0.transport == .builtIn)
        }
        let best = candidates.enumerated().min { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if rank(a.transport) != rank(b.transport) { return rank(a.transport) > rank(b.transport) }
            if a.nominalSampleRate != b.nominalSampleRate { return a.nominalSampleRate > b.nominalSampleRate }
            return lhs.offset < rhs.offset
        }?.element
        guard let best else { return InputDeviceChoice(deviceID: nil, reason: .noAlternative) }
        return InputDeviceChoice(deviceID: best.id, reason: .replacedBluetooth(replacing: defaultInput))
    }

    private static func rank(_ transport: AudioTransport) -> Int {
        transport == .wired ? 2 : 1
    }
}
