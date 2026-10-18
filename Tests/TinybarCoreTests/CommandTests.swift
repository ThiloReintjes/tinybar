import Foundation
@testable import TinybarCore
import Testing

// MARK: Shell commands

@Test func shellCommandsNameTheirPrograms() {
    let p = ShellCommand.parse(#"S=/tmp/x cd /repo && git status --short | head -20; FOO=1 rg "a|b; c" src 2>&1 | tail -n 5"#)
    #expect(p.programs == ["git", "head", "rg", "tail"])
    #expect(p.git == ["status"])
    #expect(p.headTail)
    #expect(!p.inlinePython)
}

@Test func shellCommandsSkipHeredocBodiesAndComments() {
    let command = """
        # check the data
        python3 - <<'PY'
        import json
        for row in rows: print(row)
        PY
        echo done
        """
    let p = ShellCommand.parse(command)
    #expect(p.programs == ["python"])
    #expect(p.inlinePython)
}

@Test func shellCommandsSeeWrappersKeywordsAndScripts() {
    #expect(ShellCommand.parse("for f in *.md; do wc -l \"$f\"; done").programs == ["wc"])
    #expect(ShellCommand.parse("timeout 30 sudo -u me /usr/bin/python3.12 -m http.server").programs == ["python"])
    #expect(!ShellCommand.parse("python3 -m pytest -q").inlinePython)
    #expect(ShellCommand.parse("./Scripts/deploy-acme.sh --prod").programs == ["script"])
    #expect(ShellCommand.parse("if [ -f x ]; then cat x; fi").programs == ["cat"])
    #expect(ShellCommand.parse("echo $(git rev-parse HEAD) > out.txt").programs == ["git"])
    #expect(ShellCommand.parse("git -C ../other log --oneline").git == ["log"])
    #expect(ShellCommand.parse("node -e 'console.log(1)'").inlineJS)
    #expect(ShellCommand.parse("uv run python -c 'print(1)'").inlinePython)
    #expect(!ShellCommand.parse("grep -c x f | cat").headTail)
}

@Test func shellCommandStatsCountOncePerCommand() {
    let v = ShellCommand.stats("git add -A && git commit -m x && git status")
    #expect(v[StatKey.commands] == 1)
    #expect(v[StatKey.program("git")] == 1)
    #expect(v[StatKey.git("commit")] == 1)
    #expect(v[StatKey.git("status")] == 1)
    #expect(v[StatKey.commandChars] == 43)
    #expect(ShellCommand.text(argv: ["/bin/zsh", "-lc", "ls -la"]) == "ls -la")
}

@Test func fileKindsAndLanguages() {
    #expect(FileKind.of(path: "/a/Sources/App.Swift") == "swift")
    #expect(FileKind.of(path: "Dockerfile") == "dockerfile")
    #expect(FileKind.of(path: "/a/.env") == "none")
    #expect(FileKind.of(path: "README") == "none")
    #expect(FileKind.language("tsx") == "TypeScript")
    #expect(FileKind.language("zig") == ".zig")
}

@Test func patchesSplitByFile() {
    let patch = "*** Begin Patch\n*** Add File: a.py\n+one\n+two\n*** Update File: src/b.ts\n@@\n-x\n+y\n*** End Patch"
    let files = LineCount.files(inPatch: patch)
    #expect(files.map(\.path) == ["a.py", "src/b.ts"])
    #expect(files.map(\.added) == [2, 1])
    #expect(files.map(\.removed) == [0, 1])
    let diff = "--- a/x.swift\n+++ b/x.swift\n@@ -1 +1 @@\n-a\n+b\n+c"
    #expect(LineCount.files(inPatch: diff).map(\.path) == ["x.swift"])
}

// MARK: Ingest

private func ts(_ seconds: Int) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date(timeIntervalSince1970: 1_790_000_000 + Double(seconds)))
}

private func assistant(_ id: String, at s: Int, _ blocks: String) -> String {
    #"{"type":"assistant","uuid":"a-\#(id)-\#(s)","timestamp":"\#(ts(s))","message":{"id":"\#(id)","model":"claude-opus-5-5","content":[\#(blocks)],"usage":{"input_tokens":10,"output_tokens":5}}}"#
}

private func bash(_ id: String, _ command: String) -> String {
    #"{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"\#(command)"}}"#
}

private func result(_ id: String, at s: Int, error: String? = nil) -> String {
    let body = error.map { #""content":"\#($0)","is_error":true"# } ?? #""content":"ok""#
    return #"{"type":"user","uuid":"r-\#(id)","timestamp":"\#(ts(s))","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)",\#(body)}]}}"#
}

@Test func claudeCommandsCountTheirProgramsOutcomesAndParallelCalls() async throws {
    let edit = #"{"type":"user","uuid":"r-e","timestamp":"\#(ts(9))","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"e","content":"ok"}]},"toolUseResult":{"filePath":"/p/App.swift","structuredPatch":[{"lines":["+a","+b","-c"]}]}}"#
    let lines = [
        assistant("m1", at: 1, bash("b1", "git status | head")),
        assistant("m1", at: 2, bash("b2", "rg foo")),
        result("b1", at: 3),
        result("b2", at: 4, error: "Exit code 1"),
        assistant("m2", at: 5, bash("b3", "rm -rf /")),
        result("b3", at: 6, error: "BLOCKED by a hook"),
        assistant("m3", at: 7, #"{"type":"tool_use","id":"e","name":"Edit","input":{}}"#),
        edit,
    ]
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = dir.appendingPathComponent("projects/p/s.jsonl")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Twice, as a resumed session would: nothing counts twice.
    try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("projects/p/t.jsonl"), atomically: true, encoding: .utf8)
    let store = try UsageStore(path: dir.appendingPathComponent("db.sqlite"))
    try await store.ingestClaude(roots: [dir.appendingPathComponent("projects")])
    var t: [String: Int64] = [:]
    for row in try await store.stats(since: "0000") { t[row.key, default: 0] += row.value }
    #expect(t[StatKey.commands] == 3)
    #expect(t[StatKey.program("git")] == 1)
    #expect(t[StatKey.pipedHeadTail] == 1)
    #expect(t[StatKey.commandsFinished] == 3)
    #expect(t[StatKey.commandsFailed] == 1)
    #expect(t[StatKey.parallel] == 1)
    #expect(t[StatKey.extAddedPrefix + "swift"] == 2)
    #expect(t[StatKey.extRemovedPrefix + "swift"] == 1)
    #expect(t[StatKey.extEditsPrefix + "swift"] == 1)
    #expect(t[StatKey.linesAdded] == 2)
}

private func codex(_ s: Int, _ type: String, _ payload: String) -> String {
    #"{"timestamp":"\#(ts(s))","type":"\#(type)","payload":\#(payload)}"#
}

@Test func codexCommandsFilesAndParallelScripts() {
    var parser = CodexLogParser()
    var t: [String: Int64] = [:]
    let lines = [
        codex(1, "event_msg", #"{"type":"item_completed","item":{"type":"CommandExecution","id":"c","command":["/bin/zsh","-lc","grep -rn \"x]\" . | tail -3"],"cwd":"/p","aggregated_output":"lots","exit_code":2}}"#),
        codex(2, "event_msg", #"{"type":"item_completed","item":{"type":"FileChange","id":"f","changes":{"/p/a.py":{"type":"add","content":"a\nb\n"},"/p/b.md":{"type":"update","unified_diff":"@@\n-x\n+y\n+z"}}}}"#),
        codex(3, "response_item", #"{"type":"custom_tool_call","name":"exec","input":"await Promise.all([tools.exec_command({cmd:\"ls\"})])"}"#),
        codex(4, "response_item", #"{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"python3 -c 'print(1)'\"]}"}"#),
    ]
    for line in lines { _ = parser.consume(line: Data(line.utf8)) { t.merge($0.values, uniquingKeysWith: +) } }
    #expect(t[StatKey.tool("Shell")] == 2)
    #expect(t[StatKey.commands] == 2)
    #expect(t[StatKey.program("grep")] == 1)
    #expect(t[StatKey.pipedHeadTail] == 1)
    #expect(t[StatKey.inlinePython] == 1)
    #expect(t[StatKey.commandsFinished] == 1)
    #expect(t[StatKey.commandsFailed] == 1)
    #expect(t[StatKey.extAddedPrefix + "py"] == 2)
    #expect(t[StatKey.extAddedPrefix + "md"] == 2)
    #expect(t[StatKey.extRemovedPrefix + "md"] == 1)
    #expect(t[StatKey.linesAdded] == 4)
    #expect(t[StatKey.tool("Edit")] == 1)
    #expect(t[StatKey.parallel] == 1)
}

// MARK: Summary

@Test func summaryRanksModelsAndGroupsLanguages() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
    let day = "2026-10-15"
    let usage = [
        DailyUsage(day: day, provider: .claude, model: "m", project: "", tokens: TokenCounts(input: 10)),
        DailyUsage(day: day, provider: .codex, model: "g", project: "", tokens: TokenCounts(input: 30)),
        DailyUsage(day: day, provider: .codex, model: "few", project: "", tokens: TokenCounts(input: 1)),
    ]
    func stat(_ p: ProviderID, _ model: String, _ key: String, _ v: Int64) -> DailyStat {
        DailyStat(day: day, provider: p, model: model, key: key, value: v)
    }
    let stats = [
        stat(.claude, "m", StatKey.commands, 40), stat(.claude, "m", StatKey.pipedHeadTail, 20),
        stat(.claude, "m", StatKey.program("grep"), 30), stat(.claude, "m", StatKey.program("git"), 10),
        stat(.codex, "g", StatKey.commands, 60), stat(.codex, "g", StatKey.pipedHeadTail, 6),
        stat(.codex, "g", StatKey.program("rg"), 30), stat(.codex, "g", StatKey.program("git"), 20),
        stat(.codex, "g", StatKey.inlinePython, 9), stat(.codex, "g", StatKey.inlineJS, 3),
        stat(.codex, "few", StatKey.commands, 5), stat(.codex, "few", StatKey.pipedHeadTail, 5),
        stat(.claude, "m", StatKey.extAddedPrefix + "ts", 70), stat(.claude, "m", StatKey.extAddedPrefix + "tsx", 30),
        stat(.claude, "m", StatKey.extEditsPrefix + "ts", 4), stat(.codex, "g", StatKey.extAddedPrefix + "py", 20),
        stat(.codex, "g", StatKey.extRemovedPrefix + "py", 5),
    ]
    let s = StatsSummary.build(usage: usage, stats: stats, allDays: [day], range: .week, prices: .empty, now: now, calendar: cal)
    #expect(s.commands.count == 105)
    #expect(s.commands.programs.map(\.name) == ["git", "grep", "rg"])
    #expect(s.commands.programs.first?.byProvider == [.claude: 10, .codex: 20])
    #expect(s.languages.map(\.name) == ["TypeScript", "Python"])
    #expect(s.languages.first?.totalAdded == 100)
    #expect(s.languages.first?.edits == 4)
    #expect(s.languages.last?.removed == 5)
    // "few" has too few commands to rank.
    #expect(ModelMetric.pipedHeadTail.ranked(s.models).map(\.model.name) == ["m", "g"])
    #expect(ModelMetric.pipedHeadTail.ranked(s.models).map(\.value) == [0.5, 0.1])
    #expect(ModelMetric.grep.ranked(s.models).map(\.value) == [1, 0])
    let g = s.models.first { $0.name == "g" }!
    #expect(ModelMetric.inline.value(g) == 0.2)
    #expect(ModelMetric.inline.pythonPart(g) == 0.15)

    let picked = StatsSummary.build(usage: usage, stats: stats, allDays: [day], range: .week, model: "m", prices: .empty, now: now, calendar: cal)
    #expect(picked.commands.count == 40)
    #expect(picked.languages.map(\.name) == ["TypeScript"])
    #expect(ModelMetric.pipedHeadTail.ranked(picked.models).count == 2)
}
