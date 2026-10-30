import AVFoundation
import CoreAudio
import TapLessDomain

/// Устройства ввода CoreAudio и привязка к ним модуля ввода движка.
extension AudioRecorder {
    // MARK: - Список устройств

    /// Устройство ввода по умолчанию.
    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// Все устройства CoreAudio со статическими свойствами. Микрофоны не открываются:
    /// запись с Bluetooth-гарнитуры переводит её в профиль HFP.
    static func allDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            AudioInputDevice(
                id: id,
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "",
                name: deviceName(id) ?? "?",
                transport: transport(uint32Property(id, kAudioDevicePropertyTransportType)),
                // Свойства нет — считаем устройство живым: оно есть в списке системы.
                isAlive: uint32Property(id, kAudioDevicePropertyDeviceIsAlive).map { $0 != 0 } ?? true,
                hasInput: (inputChannels(id) ?? 0) > 0,
                nominalSampleRate: nominalSampleRate(id)
            )
        }
    }

    /// Живые устройства с входом: список для меню «Микрофон».
    static func inputDevices() -> [AudioInputDevice] {
        allDevices().filter(\.isUsableInput)
    }

    /// Устройство встроенное (`kAudioDeviceTransportTypeBuiltIn`): микрофон самого Mac.
    static func isBuiltIn(_ device: AudioDeviceID) -> Bool {
        transport(uint32Property(device, kAudioDevicePropertyTransportType)) == .builtIn
    }

    private static func transport(_ value: UInt32?) -> AudioTransport {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeAVB, kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeHDMI:
            return .wired
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return .virtual
        default: return .other
        }
    }

    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return 0 }
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr ? rate : 0
    }

    // MARK: - Агрегат
    //
    // AVAudioEngine на macOS сам собирает «CADefaultDeviceAggregate-<pid>-N» из устройств ввода и вывода
    // по умолчанию, и `kAudioOutputUnitProperty_CurrentDevice` модуля ввода возвращает этот агрегат, а не
    // микрофон. id агрегата меняется с каждым движком, поэтому для лога и сверки нужен реальный вход.

    /// Устройство, к которому привязан модуль ввода, и агрегат, если модуль смотрит на него.
    struct ResolvedInput: Equatable {
        /// Реальное устройство ввода. Агрегат разобрать не удалось — сам агрегат.
        var device: AudioDeviceID
        /// Агрегат, через который идёт вход; nil — модуль привязан к устройству напрямую.
        var aggregate: AudioDeviceID?
        /// Модуль указывал не на ожидаемый вход, а на другое устройство (VPIO: устройство вывода), и `device` взят из настройки.
        var outputDevice: AudioDeviceID? = nil
    }

    /// С VPIO модуль указывает на устройство вывода (в логе было «Динамики MacBook Pro»), а не на микрофон,
    /// и тогда реальным входом считается `expected` — выбранный микрофон или устройство ввода по умолчанию.
    static func resolvedInput(of unit: AudioUnit, expected: AudioDeviceID?) -> ResolvedInput? {
        guard let current = currentDevice(of: unit) else { return nil }
        if isAggregate(current) {
            guard let real = inputSubDevice(of: current) else { return ResolvedInput(device: current, aggregate: nil) }
            return ResolvedInput(device: real, aggregate: current)
        }
        // С VPIO модуль смотрит на устройство вывода, и у него бывают входные каналы (на звонке —
        // «Динамики MacBook Pro»), поэтому сверка по `expected`, а не по числу каналов.
        if let expected, current != expected {
            return ResolvedInput(device: expected, aggregate: nil, outputDevice: current)
        }
        return ResolvedInput(device: current, aggregate: nil)
    }

    /// Устройство, которое должно быть входом при такой настройке: выбранное или по умолчанию.
    static func expectedInput(for setting: MicrophoneSetting) -> AudioDeviceID? {
        choice(for: setting).deviceID ?? defaultInputDevice()
    }

    private static func isAggregate(_ device: AudioDeviceID) -> Bool {
        let type = uint32Property(device, kAudioDevicePropertyTransportType)
        return type == kAudioDeviceTransportTypeAggregate || type == kAudioDeviceTransportTypeAutoAggregate
    }

    /// Подустройство агрегата, у которого есть входные каналы. Сначала активные подустройства
    /// (`kAudioAggregateDevicePropertyActiveSubDeviceList`), потом полный список по UID.
    /// Если входных несколько, берётся устройство ввода по умолчанию, иначе первое.
    private static func inputSubDevice(of aggregate: AudioDeviceID) -> AudioDeviceID? {
        var subDevices = objectIDs(aggregate, kAudioAggregateDevicePropertyActiveSubDeviceList)
        if subDevices.isEmpty {
            subDevices = uidList(aggregate, kAudioAggregateDevicePropertyFullSubDeviceList).compactMap(deviceID(forUID:))
        }
        let withInput = subDevices.filter { (inputChannels($0) ?? 0) > 0 }
        if let preferred = defaultInputDevice(), withInput.contains(preferred) { return preferred }
        return withInput.first
    }

    private static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectHasProperty(object, &address),
              AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uidList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return [] }
        var list: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr, let list else { return [] }
        return (list.takeRetainedValue() as? [String]) ?? []
    }

    /// `kAudioHardwarePropertyTranslateUIDToDevice`.
    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var qualifier = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }

    // MARK: - Выбор и привязка

    /// Какой микрофон нужен при такой настройке (по текущему списку устройств).
    static func choice(for setting: MicrophoneSetting) -> InputDeviceChoice {
        InputDeviceSelection.choose(devices: allDevices(), defaultInput: defaultInputDevice(), setting: setting)
    }

    /// Привязывает модуль ввода к выбранному устройству. Вызывать сразу после получения `inputNode`
    /// и до чтения формата, `installTap` и `prepare`. Не вышло или привязка не нужна — остаётся устройство
    /// по умолчанию. Возвращает пометку для лога (почему выбрано это устройство) или nil.
    static func bindInputDevice(_ input: AVAudioInputNode, setting: MicrophoneSetting, logWarnings: Bool = true) -> String? {
        let devices = allDevices()
        let defaultID = defaultInputDevice()
        let choice = InputDeviceSelection.choose(devices: devices, defaultInput: defaultID, setting: setting)
        func name(_ id: UInt32?) -> String {
            id.flatMap { id in devices.first { $0.id == id }?.name } ?? "?"
        }
        if logWarnings, let wanted = choice.unavailableRequest {
            Log.warning("Микрофон «\(wanted)» из настроек не найден или недоступен — выбор как для «auto»", .audio)
        }
        guard let target = choice.deviceID else {
            if logWarnings, choice.reason == .noAlternative {
                Log.warning("Устройство ввода по умолчанию — Bluetooth «\(name(defaultID))», другого микрофона нет: "
                            + "запись переведёт гарнитуру в профиль HFP (глухой звук в наушниках)", .audio)
            }
            return choice.reason == .noAlternative ? "Bluetooth, другого микрофона нет" : nil
        }
        guard let unit = input.audioUnit else {
            Log.warning("Не удалось привязать микрофон «\(name(target))»: у модуля ввода нет audioUnit — остаётся устройство по умолчанию", .audio)
            return nil
        }
        var device = target
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        // Модуль мог остаться на агрегате движка: тогда сверяется его входное подустройство.
        let resolved = status == noErr ? resolvedInput(of: unit, expected: nil) : nil
        Log.debug("Привязка микрофона «\(name(target))»: OSStatus \(status), модуль указывает на "
                  + (resolved.map { r in r.aggregate.map { "агрегат \($0), вход «\(name(r.device))»" } ?? "устройство «\(name(r.device))» напрямую" } ?? "?"), .audio)
        guard resolved?.device == target else {
            if logWarnings {
                Log.warning("Не удалось привязать микрофон «\(name(target))» (OSStatus \(status)) — остаётся устройство по умолчанию", .audio)
            }
            return nil
        }
        switch choice.reason {
        case .replacedBluetooth(let replacing): return "выбран вместо Bluetooth «\(name(replacing))»"
        case .explicit: return "выбран в настройках"
        default: return nil
        }
    }
}
