import Testing
@testable import TapLessDomain

@Suite struct MicrophoneSettingTests {
    @Test func autoAndEmpty() {
        #expect(MicrophoneSetting("auto") == .auto)
        #expect(MicrophoneSetting("") == .auto)
        #expect(MicrophoneSetting("   ") == .auto)
    }

    @Test func systemIgnoresCaseAndSpaces() {
        #expect(MicrophoneSetting("system") == .system)
        #expect(MicrophoneSetting("  SyStem \n") == .system)
        #expect(MicrophoneSetting(" AUTO ") == .auto)
    }

    @Test func deviceKeepsCaseAndTrimsSpaces() {
        #expect(MicrophoneSetting("BuiltInMicrophoneDevice") == .device("BuiltInMicrophoneDevice"))
        #expect(MicrophoneSetting("  MacBook Pro Microphone ") == .device("MacBook Pro Microphone"))
        #expect(MicrophoneSetting("AppleUSBAudioEngine:Foo:Bar:1") == .device("AppleUSBAudioEngine:Foo:Bar:1"))
    }

    @Test func autoLikeNamesAreDevices() {
        #expect(MicrophoneSetting("auto mic") == .device("auto mic"))
        #expect(MicrophoneSetting("systems") == .device("systems"))
    }

    @Test func rawValueRoundTrips() {
        #expect(MicrophoneSetting.auto.rawValue == "auto")
        #expect(MicrophoneSetting.system.rawValue == "system")
        #expect(MicrophoneSetting.device("UID-1").rawValue == "UID-1")
        for raw in ["auto", "system", "UID-1"] {
            #expect(MicrophoneSetting(MicrophoneSetting(raw).rawValue) == MicrophoneSetting(raw))
        }
    }
}
