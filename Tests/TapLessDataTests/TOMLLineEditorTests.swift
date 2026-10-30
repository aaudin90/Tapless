import Foundation
import Testing
@testable import TapLessData

@Suite struct TOMLLineEditorTests {
    private func set(_ value: String, in text: String, key: String = "microphone", table: String = "general") -> String {
        TOMLLineEditor.setValue(TOMLLineEditor.stringLiteral(value), forKey: key, inTable: table, in: text)
    }

    @Test func replacesSingleQuotedValueAndKeepsComment() {
        let result = set("system", in: "[general]\nmicrophone = 'a # b'  # заметка\nsounds = true\n")
        #expect(result == "[general]\nmicrophone = \"system\"  # заметка\nsounds = true\n")
    }

    @Test func replacesValueInCRLFFile() {
        let result = set("system", in: "[general]\r\nmicrophone = \"auto\"  # c\r\nsounds = true\r\n")
        #expect(result == "[general]\r\nmicrophone = \"system\"  # c\r\nsounds = true\r\n")
    }

    @Test func addsKeyInCRLFFileWithCRLF() {
        let withTable = set("system", in: "[general] # c\r\nsounds = true\r\n")
        #expect(withTable == "[general] # c\r\nmicrophone = \"system\"\r\nsounds = true\r\n")
        let withoutTable = set("system", in: "[ui]\r\nwidth = 700\r\n")
        #expect(withoutTable == "[ui]\r\nwidth = 700\r\n\r\n[general]\r\nmicrophone = \"system\"\r\n")
    }

    @Test func ignoresSameKeyInOtherTable() {
        let text = "[other]\nmicrophone = \"keep\"\n\n[general]\nsounds = true\n\n[tail]\nmicrophone = \"keep2\"\n"
        let result = set("system", in: text)
        #expect(result == "[other]\nmicrophone = \"keep\"\n\n[general]\nmicrophone = \"system\"\nsounds = true\n\n[tail]\nmicrophone = \"keep2\"\n")
    }

    @Test func ignoresKeyInTableAfterTargetTable() {
        let text = "[general]\nsounds = true\n[other]\nmicrophone = \"keep\"\n"
        #expect(set("system", in: text) == "[general]\nmicrophone = \"system\"\nsounds = true\n[other]\nmicrophone = \"keep\"\n")
    }

    @Test func prefixKeyDoesNotMatch() {
        let text = "[general]\nmicrophone_x = \"keep\"\nmicrophone = \"auto\"\n"
        #expect(set("system", in: text) == "[general]\nmicrophone_x = \"keep\"\nmicrophone = \"system\"\n")
        let onlyPrefix = "[general]\nmicrophone_x = \"keep\"\n"
        #expect(set("system", in: onlyPrefix) == "[general]\nmicrophone = \"system\"\nmicrophone_x = \"keep\"\n")
    }

    @Test func tableNamePrefixDoesNotMatch() {
        let text = "[general.sub]\nmicrophone = \"keep\"\n"
        #expect(set("system", in: text) == "[general.sub]\nmicrophone = \"keep\"\n\n[general]\nmicrophone = \"system\"\n")
    }

    @Test func appendsTableToEmptyText() {
        #expect(set("system", in: "") == "[general]\nmicrophone = \"system\"\n")
    }

    @Test func appendsTableAfterTrimmingTrailingBlankLines() {
        #expect(set("system", in: "[ui]\nwidth = 700\n\n\n") == "[ui]\nwidth = 700\n\n[general]\nmicrophone = \"system\"\n")
    }

    @Test func keepsIndentation() {
        #expect(set("system", in: "[general]\n  microphone = \"auto\"\n") == "[general]\n  microphone = \"system\"\n")
    }

    @Test func integerLiteralReplacesUnquotedValue() {
        let result = TOMLLineEditor.setValue("2", forKey: "auto_select", inTable: "paste", in: "[paste]\nauto_select = 0 # c\n")
        #expect(result == "[paste]\nauto_select = 2 # c\n")
    }

    @Test func stringLiteralEscapes() {
        #expect(TOMLLineEditor.stringLiteral("plain") == "\"plain\"")
        #expect(TOMLLineEditor.stringLiteral("a\"b") == "\"a\\\"b\"")
        #expect(TOMLLineEditor.stringLiteral("a\\b") == "\"a\\\\b\"")
        #expect(TOMLLineEditor.stringLiteral("a\nb\rc\td") == "\"a\\nb\\rc\\td\"")
        #expect(TOMLLineEditor.stringLiteral("\u{01}\u{7F}") == "\"\\u0001\\u007F\"")
        #expect(TOMLLineEditor.stringLiteral("Микрофон") == "\"Микрофон\"")
        #expect(TOMLLineEditor.stringLiteral("") == "\"\"")
    }

    @Test func literalRoundTripsThroughParser() throws {
        let value = "He said \"hi\" \\ path\tтаб #1 \u{01}"
        let text = set(value, in: "[general]\nmicrophone = \"auto\"\n")
        let table = try FileConfigRepository.table(fromTOML: text)
        #expect((table["general"] as? [String: Any])?["microphone"] as? String == value)
    }
}
