import Foundation
import Testing
@testable import TapLessData
import TapLessDomain

@Suite final class FileLogTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapless-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var logURL: URL { directory.appendingPathComponent("test.log") }
    private var rotatedURL: URL { directory.appendingPathComponent("test.log.1") }

    private func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test func rotatesDuringWork() {
        let writer = LogFileWriter(url: logURL, maxBytes: 200)
        for i in 0..<4 { writer.write(.info, .app, "запись \(i) " + String(repeating: "x", count: 30)) }
        writer.flush()

        #expect(FileManager.default.fileExists(atPath: rotatedURL.path))
        #expect(text(rotatedURL).contains("запись 0 "))
        #expect(text(logURL).contains("запись 3 "))
        #expect(!text(logURL).contains("запись 0 "))
    }

    @Test func installMovesBigFileToRotated() {
        try? Data(repeating: 0x61, count: 500).write(to: logURL)
        let writer = LogFileWriter(url: logURL, maxBytes: 200)
        writer.rotateIfNeeded()

        #expect(!FileManager.default.fileExists(atPath: logURL.path))
        #expect(text(rotatedURL).count == 500)
    }

    @Test func rotationReplacesOldRotatedFile() {
        try? Data("старый".utf8).write(to: rotatedURL)
        try? Data(repeating: 0x61, count: 500).write(to: logURL)
        let writer = LogFileWriter(url: logURL, maxBytes: 200)
        writer.rotateIfNeeded()

        #expect(!text(rotatedURL).contains("старый"))
    }

    @Test func smallFileIsKept() {
        let writer = LogFileWriter(url: logURL, maxBytes: 10_000)
        writer.write(.info, .app, "один")
        writer.write(.info, .app, "два")
        writer.flush()

        #expect(!FileManager.default.fileExists(atPath: rotatedURL.path))
        #expect(text(logURL).contains("один"))
        #expect(text(logURL).contains("два"))
    }

    @Test func lineFormat() {
        let line = LogFileWriter.format(date: "2026-10-15 18:21:03.123", level: .info,
                                        category: .llm, message: "привет")
        #expect(line == "2026-10-15 18:21:03.123 INFO    [llm] привет\n")
        let warn = LogFileWriter.format(date: "d", level: .warning, category: .ui, message: "m")
        #expect(warn == "d WARNING [ui] m\n")
    }

    @Test func writtenLineHasTimestampLevelCategory() throws {
        let writer = LogFileWriter(url: logURL)
        writer.write(.error, .stt, "сбой")
        writer.flush()

        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} ERROR   \[stt\] сбой\n$"#
        #expect(text(logURL).range(of: pattern, options: .regularExpression) != nil)
    }

    @Test func defaultLimitIsFiveMegabytes() {
        #expect(LogFileWriter.defaultMaxBytes == 5_000_000)
    }
}
