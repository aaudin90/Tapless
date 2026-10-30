import Testing
@testable import TapLessDomain

struct InputDeviceSelectionTests {
    private func device(_ id: UInt32, _ name: String, _ transport: AudioTransport, alive: Bool = true,
                        input: Bool = true, rate: Double = 48_000) -> AudioInputDevice {
        AudioInputDevice(id: id, uid: "uid-\(id)", name: name, transport: transport, isAlive: alive,
                         hasInput: input, nominalSampleRate: rate)
    }

    private var builtIn: AudioInputDevice { device(1, "MacBook Pro Microphone", .builtIn) }
    private var bluetooth: AudioInputDevice { device(2, "AirPods", .bluetooth, rate: 16_000) }
    private var usb: AudioInputDevice { device(3, "USB Mic", .wired) }

    private func choose(_ devices: [AudioInputDevice], default id: UInt32?, _ setting: MicrophoneSetting = .auto) -> InputDeviceChoice {
        InputDeviceSelection.choose(devices: devices, defaultInput: id, setting: setting)
    }

    // MARK: Разбор значения

    @Test func settingParsing() {
        #expect(MicrophoneSetting("") == .auto)
        #expect(MicrophoneSetting("  ") == .auto)
        #expect(MicrophoneSetting("auto") == .auto)
        #expect(MicrophoneSetting("AUTO") == .auto)
        #expect(MicrophoneSetting("system") == .system)
        #expect(MicrophoneSetting(" System ") == .system)
        #expect(MicrophoneSetting("BuiltInMicrophoneDevice") == .device("BuiltInMicrophoneDevice"))
        #expect(MicrophoneSetting.device("X").rawValue == "X")
        #expect(MicrophoneSetting.auto.rawValue == "auto")
        #expect(MicrophoneSetting.system.rawValue == "system")
    }

    // MARK: auto

    @Test func autoBluetoothDefaultSwitchesToBuiltIn() {
        let result = choose([bluetooth, builtIn], default: 2)
        #expect(result == InputDeviceChoice(deviceID: 1, reason: .replacedBluetooth(replacing: 2)))
    }

    @Test func autoWiredBeatsBuiltIn() {
        let result = choose([bluetooth, builtIn, usb], default: 2)
        #expect(result.deviceID == 3)
        #expect(result.reason == .replacedBluetooth(replacing: 2))
    }

    @Test func autoPrefersHigherSampleRateAmongEquals() {
        let slow = device(5, "USB 16k", .wired, rate: 16_000)
        let fast = device(6, "USB 96k", .wired, rate: 96_000)
        #expect(choose([bluetooth, slow, fast], default: 2).deviceID == 6)
        #expect(choose([bluetooth, fast, slow], default: 2).deviceID == 6)
    }

    @Test func autoEqualCandidatesKeepListOrder() {
        let first = device(5, "A", .wired)
        let second = device(6, "B", .wired)
        #expect(choose([bluetooth, first, second], default: 2).deviceID == 5)
    }

    @Test func autoSkipsVirtualAggregateAndOtherBluetooth() {
        let virtual = device(7, "BlackHole", .virtual)
        let aggregate = device(8, "Aggregate", .virtual)
        let otherBluetooth = device(9, "Headset 2", .bluetooth)
        let unknown = device(10, "Unknown", .other)
        let result = choose([bluetooth, virtual, aggregate, otherBluetooth, unknown], default: 2)
        #expect(result == InputDeviceChoice(deviceID: nil, reason: .noAlternative))
    }

    @Test func autoSkipsDeadAndOutputOnlyDevices() {
        let dead = device(1, "Built-in", .builtIn, alive: false)
        let outputOnly = device(3, "Display", .wired, input: false)
        let result = choose([bluetooth, dead, outputOnly], default: 2)
        #expect(result == InputDeviceChoice(deviceID: nil, reason: .noAlternative))
    }

    @Test func autoSkipsDeadWiredAndTakesBuiltIn() {
        let deadUSB = device(3, "USB Mic", .wired, alive: false)
        #expect(choose([bluetooth, deadUSB, builtIn], default: 2).deviceID == 1)
    }

    @Test func autoKeepsNonBluetoothDefault() {
        #expect(choose([usb, builtIn, bluetooth], default: 3) == InputDeviceChoice(deviceID: nil, reason: .defaultKept))
        #expect(choose([builtIn, bluetooth], default: 1) == InputDeviceChoice(deviceID: nil, reason: .defaultKept))
    }

    @Test func autoWithoutDefaultKeepsSystem() {
        #expect(choose([bluetooth, builtIn], default: nil) == InputDeviceChoice(deviceID: nil, reason: .noDefault))
    }

    // MARK: system

    @Test func systemAlwaysKeepsDefault() {
        let result = choose([bluetooth, builtIn, usb], default: 2, .system)
        #expect(result == InputDeviceChoice(deviceID: nil, reason: .systemRequested))
    }

    // MARK: конкретное устройство

    @Test func explicitMatchesByUID() {
        let result = choose([bluetooth, builtIn, usb], default: 2, .device("uid-1"))
        #expect(result == InputDeviceChoice(deviceID: 1, reason: .explicit))
    }

    @Test func explicitMatchesByNameIgnoringCase() {
        let result = choose([bluetooth, builtIn, usb], default: 2, .device("usb mic"))
        #expect(result == InputDeviceChoice(deviceID: 3, reason: .explicit))
    }

    @Test func explicitUIDWinsOverName() {
        let byName = device(11, "uid-12", .wired)
        let byUID = device(12, "Other", .wired)
        #expect(choose([byName, byUID], default: 11, .device("uid-12")).deviceID == 12)
    }

    @Test func explicitMayBeBluetooth() {
        let result = choose([bluetooth, builtIn], default: 1, .device("uid-2"))
        #expect(result == InputDeviceChoice(deviceID: 2, reason: .explicit))
    }

    @Test func explicitMissingFallsBackToAuto() {
        let result = choose([bluetooth, builtIn], default: 2, .device("Нет такого"))
        #expect(result == InputDeviceChoice(deviceID: 1, reason: .replacedBluetooth(replacing: 2), unavailableRequest: "Нет такого"))
    }

    @Test func explicitDeadFallsBackToAuto() {
        let dead = device(3, "USB Mic", .wired, alive: false)
        let result = choose([dead, builtIn], default: 1, .device("uid-3"))
        #expect(result == InputDeviceChoice(deviceID: nil, reason: .defaultKept, unavailableRequest: "uid-3"))
    }

    @Test func explicitWithoutInputFallsBackToAuto() {
        let outputOnly = device(3, "USB Mic", .wired, input: false)
        let result = choose([outputOnly, builtIn], default: 1, .device("USB Mic"))
        #expect(result.unavailableRequest == "USB Mic")
        #expect(result.deviceID == nil)
    }
}
