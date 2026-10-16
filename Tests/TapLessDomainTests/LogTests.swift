import Testing
@testable import TapLessDomain

@Suite struct LogTests {
    @Test func levelNamesFromConfig() {
        #expect(LogLevel(name: "debug") == .debug)
        #expect(LogLevel(name: " INFO ") == .info)
        #expect(LogLevel(name: "Warning") == .warning)
        #expect(LogLevel(name: "error") == .error)
        #expect(LogLevel(name: "verbose") == nil)
        #expect(LogLevel.debug < .info && LogLevel.warning < .error)
    }

    @Test func logConfigFallsBackToDebug() {
        #expect(LogConfig(level: "info", includeText: false).logLevel == .info)
        #expect(LogConfig(level: "nope", includeText: false).logLevel == .debug)
    }

    @Test func userTextIsHiddenByDefault() {
        let saved = Log.includeText
        defer { Log.includeText = saved }
        Log.includeText = false
        #expect(Log.text("секрет") == "‹6 симв.›")
        Log.includeText = true
        #expect(Log.text("секрет") == "«секрет»")
    }
}
