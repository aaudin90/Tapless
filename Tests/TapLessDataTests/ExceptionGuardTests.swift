import Foundation
import Testing
import TapLessObjCSupport

@Suite struct ExceptionGuardTests {
    @Test func exceptionBecomesError() {
        var ran = 0
        var caught: NSError?
        do {
            try TLExceptionGuard.runGuarded {
                ran += 1
                NSException(name: NSExceptionName("TestException"), reason: "причина теста", userInfo: nil).raise()
            }
        } catch {
            caught = error as NSError
        }
        #expect(ran == 1)
        let info = caught?.userInfo
        #expect(caught?.domain == TLExceptionErrorDomain)
        #expect(info?[TLExceptionNameKey] as? String == "TestException")
        #expect(info?[TLExceptionReasonKey] as? String == "причина теста")
    }

    @Test func successRunsOnce() throws {
        var ran = 0
        try TLExceptionGuard.runGuarded { ran += 1 }
        #expect(ran == 1)
    }
}
