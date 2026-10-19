import Foundation
@testable import TinybarCore
import Testing

@Test func attachedRedirectionsNeverCountDestinationNames() {
    #expect(ShellCommand.parse("ls>/dev/null").programs == ["ls"])
    #expect(ShellCommand.parse("2>/dev/null git status").programs == ["git"])
    #expect(ShellCommand.parse("2>&1 git status").programs == ["git"])
    #expect(ShellCommand.parse("ls&>/dev/null").programs == ["ls"])
}

@Test func quotedHeredocDelimitersAndLeadingInlineCode() {
    #expect(ShellCommand.parse("cat <<'END CODE'\nx\nEND CODE\ngit status").programs == ["cat", "git"])
    #expect(ShellCommand.parse("cat <<END\\ CODE\nx\nEND CODE\ngit status").programs == ["cat", "git"])
    #expect(ShellCommand.parse("<<EOF python3\nprint(1)\nEOF").inlinePython)
    #expect(!ShellCommand.parse("<<EOF python3 script.py\ninput\nEOF").inlinePython)
}

@Test func legacyShellCallsCountCommandHabits() {
    for padding in ["", String(repeating: " ", count: 10)] {
        let payload = #"{"timestamp":"2026-09-25T10:00:00Z","type":"response_item","payload":{"padding":"\#(padding)","type":"local_shell_call","action":{"command":["bash","-lc","git status | head"]}}}"#
        var parser = CodexLogParser()
        var values: [String: Int64] = [:]
        _ = parser.consume(line: Data(payload.utf8)) { event in values.merge(event.values, uniquingKeysWith: +) }
        #expect(values[StatKey.commands] == 1)
        #expect(values[StatKey.program("git")] == 1)
        #expect(values[StatKey.pipedHeadTail] == 1)
    }
}
