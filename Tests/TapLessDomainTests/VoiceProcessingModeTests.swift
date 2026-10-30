import Testing
@testable import TapLessDomain

struct VoiceProcessingModeTests {
    @Test func parsing() {
        #expect(VoiceProcessingMode("off") == .off)
        #expect(VoiceProcessingMode("call") == .call)
        #expect(VoiceProcessingMode(" CALL ") == .call)
        #expect(VoiceProcessingMode("Off") == .off)
        #expect(VoiceProcessingMode("") == .off)
        #expect(VoiceProcessingMode("always") == .off)
    }

    @Test func validity() {
        #expect(VoiceProcessingMode.isValid("off"))
        #expect(VoiceProcessingMode.isValid("call"))
        #expect(VoiceProcessingMode.isValid(" Call"))
        #expect(!VoiceProcessingMode.isValid(""))
        #expect(!VoiceProcessingMode.isValid("on"))
    }

    @Test func rawValues() {
        #expect(VoiceProcessingMode.off.rawValue == "off")
        #expect(VoiceProcessingMode.call.rawValue == "call")
    }

    @Test func callInputIsBuiltInWithThreeOrMoreChannels() {
        #expect(VoiceProcessingMode.isCallInput(inputChannels: 3, isBuiltIn: true))
        #expect(VoiceProcessingMode.isCallInput(inputChannels: 9, isBuiltIn: true))
        #expect(!VoiceProcessingMode.isCallInput(inputChannels: 2, isBuiltIn: true))
        #expect(!VoiceProcessingMode.isCallInput(inputChannels: 1, isBuiltIn: true))
        #expect(!VoiceProcessingMode.isCallInput(inputChannels: 0, isBuiltIn: true))
        // USB-стерео, звуковая карта, BlackHole и т. п.: не встроенные.
        #expect(!VoiceProcessingMode.isCallInput(inputChannels: 3, isBuiltIn: false))
        #expect(!VoiceProcessingMode.isCallInput(inputChannels: 16, isBuiltIn: false))
        #expect(!VoiceProcessingMode.isCallInput(inputChannels: 2, isBuiltIn: false))
    }

    @Test func callEnablesOnlyForBuiltInCallInput() {
        #expect(!VoiceProcessingMode.off.shouldEnable(inputChannels: 3, isBuiltIn: true))
        #expect(!VoiceProcessingMode.off.shouldEnable(inputChannels: 1, isBuiltIn: true))
        #expect(!VoiceProcessingMode.call.shouldEnable(inputChannels: 1, isBuiltIn: true))
        #expect(!VoiceProcessingMode.call.shouldEnable(inputChannels: 0, isBuiltIn: true))
        #expect(!VoiceProcessingMode.call.shouldEnable(inputChannels: 2, isBuiltIn: true))
        #expect(!VoiceProcessingMode.call.shouldEnable(inputChannels: 2, isBuiltIn: false))
        #expect(!VoiceProcessingMode.call.shouldEnable(inputChannels: 3, isBuiltIn: false))
        #expect(VoiceProcessingMode.call.shouldEnable(inputChannels: 3, isBuiltIn: true))
        #expect(VoiceProcessingMode.call.shouldEnable(inputChannels: 9, isBuiltIn: true))
    }
}
