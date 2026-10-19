import Foundation

/// What a shell command an agent ran tells about its habits, as stat counters: the programs it
/// runs, git subcommands, output piped into `head` or `tail`, code sent inline to an interpreter,
/// and its length. Only program names are kept; arguments, paths and the text itself are not
/// (SPEC §13).
public enum ShellCommand {
    /// The counters one command adds.
    public static func stats(_ command: String) -> [String: Int64] {
        var v: [String: Int64] = [StatKey.commands: 1, StatKey.commandChars: Int64(command.unicodeScalars.count)]
        let p = parse(command)
        for name in p.programs { v[StatKey.program(name)] = 1 }
        for sub in p.git { v[StatKey.git(sub)] = 1 }
        if p.headTail { v[StatKey.pipedHeadTail] = 1 }
        if p.inlinePython { v[StatKey.inlinePython] = 1 } else if p.inlineJS { v[StatKey.inlineJS] = 1 }
        return v
    }

    /// The script of a command given as an argument vector: `bash -lc "…"` is its script.
    public static func text(argv: [String]) -> String {
        if argv.count >= 3, ["bash", "zsh", "sh"].contains(basename(argv[0])), ["-lc", "-c"].contains(argv[1]) {
            return argv[2]
        }
        if argv.count == 1 { return argv[0] }  // a logged script, rather than an argv
        return argv.map { word in
            if !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || "_./:-=".contains($0) }) { return word }
            return "'" + word.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }.joined(separator: " ")
    }

    struct Parsed: Equatable {
        var programs: Set<String> = []
        var git: Set<String> = []
        var headTail = false
        var inlinePython = false
        var inlineJS = false
    }

    private struct Segment {
        var words: [String] = []
        var afterPipe = false
    }

    static func parse(_ command: String) -> Parsed {
        var result = Parsed()
        for segment in segments(command) {
            guard let (name, at) = program(segment.words) else { continue }
            result.programs.insert(name)
            if name == "git", let sub = gitSubcommand(segment.words[(at + 1)...]) { result.git.insert(sub) }
            if segment.afterPipe, name == "head" || name == "tail" { result.headTail = true }
            switch inline(segment.words, at: at) {
            case .python?: result.inlinePython = true
            case .js?: result.inlineJS = true
            case nil: break
            }
        }
        return result
    }

    // MARK: Splitting

    /// Simple commands, split at `|`, `||`, `&&`, `;`, `&`, newlines, parentheses and backticks
    /// outside quotes. Heredoc bodies and comments are skipped.
    private static func segments(_ command: String) -> [Segment] {
        let b = Array(command.utf8)
        var out: [Segment] = []
        var seg = Segment()
        var word: [UInt8] = []
        var inWord = false
        var heredocs: [(delimiter: [UInt8], tabs: Bool)] = []
        var i = 0

        func endWord() {
            if inWord { seg.words.append(String(decoding: word, as: UTF8.self)) }
            word.removeAll(keepingCapacity: true)
            inWord = false
        }
        func endSegment(pipe: Bool = false) {
            endWord()
            if !seg.words.isEmpty { out.append(seg) }
            seg = Segment()
            seg.afterPipe = pipe
        }

        while i < b.count {
            let c = b[i]
            switch c {
            case UInt8(ascii: "'"):
                inWord = true
                i += 1
                while i < b.count, b[i] != UInt8(ascii: "'") { word.append(b[i]); i += 1 }
                i += 1
            case UInt8(ascii: "\""):
                inWord = true
                i += 1
                while i < b.count, b[i] != UInt8(ascii: "\"") {
                    if b[i] == UInt8(ascii: "\\"), i + 1 < b.count { i += 1 }
                    word.append(b[i])
                    i += 1
                }
                i += 1
            case UInt8(ascii: "\\"):
                // An escaped newline continues the line.
                if i + 1 < b.count, b[i + 1] != 0x0A { word.append(b[i + 1]); inWord = true } else { endWord() }
                i += 2
            case UInt8(ascii: " "), UInt8(ascii: "\t"):
                endWord()
                i += 1
            case 0x0A:
                endSegment()
                i += 1
                // Heredoc bodies start on the next line and run to their delimiter.
                for (delimiter, tabs) in heredocs {
                    while i < b.count {
                        var end = i
                        while end < b.count, b[end] != 0x0A { end += 1 }
                        var line = b[i..<end]
                        if tabs { line = line.drop { $0 == UInt8(ascii: "\t") } }
                        i = end + 1
                        if Array(line) == delimiter { break }
                    }
                }
                heredocs.removeAll()
            case UInt8(ascii: "#") where !inWord:
                while i < b.count, b[i] != 0x0A { i += 1 }
            case UInt8(ascii: "<") where i + 1 < b.count && b[i + 1] == UInt8(ascii: "<"):
                if i + 2 < b.count, b[i + 2] == UInt8(ascii: "<") {
                    // A here-string: its text is an argument.
                    endWord()
                    seg.words.append("<<<")
                    i += 3
                    break
                }
                endWord()
                seg.words.append("<<")
                i += 2
                var tabs = false
                if i < b.count, b[i] == UInt8(ascii: "-") { tabs = true; i += 1 }
                while i < b.count, b[i] == UInt8(ascii: " ") { i += 1 }
                var delimiter: [UInt8] = []
                while i < b.count, !isDelimiterEnd(b[i]) {
                    if b[i] != UInt8(ascii: "'"), b[i] != UInt8(ascii: "\""), b[i] != UInt8(ascii: "\\") { delimiter.append(b[i]) }
                    i += 1
                }
                seg.words.append(String(decoding: delimiter, as: UTF8.self))
                if !delimiter.isEmpty { heredocs.append((delimiter, tabs)) }
            case UInt8(ascii: "|"):
                if i + 1 < b.count, b[i + 1] == UInt8(ascii: "|") {
                    endSegment()
                    i += 2
                } else {
                    endSegment(pipe: true)
                    i += b.count > i + 1 && b[i + 1] == UInt8(ascii: "&") ? 2 : 1
                }
            case UInt8(ascii: "&"):
                // `2>&1`, `>&2` and `&>` are redirections, not separators.
                if (i > 0 && (b[i - 1] == UInt8(ascii: ">") || b[i - 1] == UInt8(ascii: "<")))
                    || (i + 1 < b.count && b[i + 1] == UInt8(ascii: ">"))
                {
                    word.append(c)
                    inWord = true
                    i += 1
                } else {
                    endSegment()
                    i += i + 1 < b.count && b[i + 1] == UInt8(ascii: "&") ? 2 : 1
                }
            case UInt8(ascii: ";"), UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "`"):
                if c == UInt8(ascii: "("), word.last == UInt8(ascii: "$") { word.removeLast() }
                endSegment()
                i += 1
            default:
                word.append(c)
                inWord = true
                i += 1
            }
        }
        endSegment()
        return out
    }

    private static func isDelimiterEnd(_ c: UInt8) -> Bool {
        c == 0x0A || c == UInt8(ascii: " ") || c == UInt8(ascii: ";") || c == UInt8(ascii: "|")
            || c == UInt8(ascii: "&") || c == UInt8(ascii: ")") || c == UInt8(ascii: "<") || c == UInt8(ascii: ">")
    }

    // MARK: Words

    /// Words that start a command but aren't the program: keywords, wrappers and negation.
    private static let prefixes: Set<String> = [
        "do", "then", "else", "elif", "if", "while", "until", "!", "{", "time", "sudo", "env", "nohup",
        "exec", "command", "builtin", "nice", "noglob", "timeout", "gtimeout",
    ]
    /// Words after which a segment runs no program of its own.
    private static let headers: Set<String> = ["for", "case", "select", "function", "done", "fi", "esac", "in", "}", "]]", "]"]
    /// Shell builtins: part of the shell, not programs it runs.
    private static let builtins: Set<String> = [
        "cd", "export", "set", "unset", "local", "source", ".", "alias", "return", "exit", "shift", "read",
        "eval", "trap", "wait", "declare", "typeset", "true", "false", ":", "pushd", "popd", "[", "[[",
        "test", "break", "continue", "let", "ulimit", "umask", "setopt", "unsetopt", "readonly", "type",
        "hash", "jobs", "fg", "bg", "disown", "kill", "shopt", "echo", "printf", "pwd", "<<", "<<<",
    ]

    private static let wrapperArguments: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-T", "-R", "-D", "--user", "--group", "--host"],
        "env": ["-u", "-C", "-S", "--unset", "--chdir", "--split-string"],
        "timeout": ["-s", "-k", "--signal", "--kill-after"],
        "gtimeout": ["-s", "-k", "--signal", "--kill-after"],
        "nice": ["-n", "--adjustment"], "time": ["-o", "-f", "--output", "--format"],
    ]

    /// The program a simple command runs, and the index of its word.
    private static func program(_ words: [String]) -> (String, Int)? {
        var i = 0
        while i < words.count {
            let w = words[i]
            if isAssignment(w) {
                i += 1
                continue
            }
            if let target = redirection(w) {
                // `> out.txt`: the file is the operator's, not a program.
                i += target ? 1 : 2
                continue
            }
            let wrapper = basename(w)
            if prefixes.contains(w) || (["sudo", "env", "nohup", "nice", "timeout", "gtimeout", "time"].contains(wrapper) && w.contains("/")) {
                i += 1
                // `timeout 30 cmd`, `env -i cmd`, `sudo -u x cmd`: skip the wrapper's own arguments.
                while i < words.count, words[i].hasPrefix("-") || (wrapper.hasSuffix("timeout") && words[i].first?.isNumber == true) {
                    i += (wrapperArguments[wrapper] ?? []).contains(words[i]) ? 2 : 1
                }
                continue
            }
            if headers.contains(w) || builtins.contains(w) { return nil }
            return name(w).map { ($0, i) }
        }
        return nil
    }

    /// Whether a word is a redirection (`>`, `2>>`, `<`, `&>`), and if so whether its file is
    /// attached (`>out.txt`) rather than the next word.
    private static func redirection(_ w: String) -> Bool? {
        let op = w.drop { $0.isNumber || $0 == "&" }
        guard op.hasPrefix(">") || op.hasPrefix("<") else { return nil }
        let rest = op.drop { $0 == ">" || $0 == "<" || $0 == "&" || $0 == "|" }
        return !rest.isEmpty || op.contains("&")
    }

    private static func isAssignment(_ w: String) -> Bool {
        guard let eq = w.firstIndex(of: "="), eq != w.startIndex else { return false }
        return w[..<eq].allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func basename(_ w: String) -> String {
        w.split(separator: "/").last.map(String.init) ?? w
    }

    private static let scriptExtensions = [".sh", ".bash", ".zsh", ".py", ".js", ".mjs", ".cjs", ".ts", ".rb", ".pl"]

    /// A program's name as stored: the basename, lowercased; `python3.12` is `python`. A script
    /// file is `script`, so its name (which may say what the project is) isn't kept.
    static func name(_ word: String) -> String? {
        guard !word.hasPrefix("$"), !word.hasPrefix("-") else { return nil }
        var n = basename(word).lowercased()
        if scriptExtensions.contains(where: n.hasSuffix) { return "script" }
        if n.hasPrefix("python"), n.dropFirst(6).allSatisfy({ $0.isNumber || $0 == "." }) { n = "python" }
        if n == "pip3" { n = "pip" }
        guard (1...32).contains(n.count), n.first!.isLetter || n.first!.isNumber,
              n.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) })
        else { return nil }
        return n
    }

    static let gitSubcommands: Set<String> = [
        "status", "diff", "log", "add", "commit", "push", "pull", "fetch", "checkout", "switch", "branch",
        "show", "rebase", "stash", "reset", "merge", "worktree", "rev-parse", "restore", "grep", "clone",
        "tag", "cherry-pick", "blame", "remote", "ls-files", "mv", "rm", "apply", "init",
    ]

    private static func gitSubcommand(_ rest: ArraySlice<String>) -> String? {
        var it = rest.makeIterator()
        while let w = it.next() {
            if ["-C", "-c", "--git-dir", "--work-tree", "--namespace"].contains(w) { _ = it.next(); continue }
            if w.hasPrefix("-") { continue }
            return gitSubcommands.contains(w) ? w : nil
        }
        return nil
    }

    private enum Language { case python, js }

    /// Code passed to an interpreter in the command itself (`python3 -c`, `python3 - <<'PY'`,
    /// `node -e`), rather than a saved script.
    private static func inline(_ words: [String], at programIndex: Int) -> Language? {
        var i = programIndex
        // `uv run python -c ...` is a runner; an argument like `rg python -c ...` isn't.
        if name(words[i]) == "uv", i + 2 < words.count, words[i + 1] == "run" { i += 2 }
        let language: Language
        let flags: Set<String>
        switch name(words[i]) {
        case "python": language = .python; flags = ["-c", "-"]
        case "node", "bun", "deno", "tsx": language = .js; flags = ["-e", "--eval", "-p", "--print", "-", "eval"]
        default: return nil
        }
        for a in words[(i + 1)...] {
            if flags.contains(a) || a == "<<" { return language }
            if a.hasPrefix("-"), !["-m", "--input-type"].contains(a) { continue }
            break
        }
        return nil
    }
}

/// What kind of file an edit touched, kept as its extension (SPEC §13): `Sources/App.swift` is
/// `swift`. Names without one are kept only when they say the kind (`Dockerfile`).
public enum FileKind {
    public static func of(path: String) -> String {
        let base = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        let named = ["dockerfile", "makefile", "gemfile", "podfile", "rakefile", "justfile", "procfile"]
        if named.contains(base) { return base }
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "none" }
        let ext = base[base.index(after: dot)...]
        guard (1...10).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "_" || $0 == "-") })
        else { return "other" }
        return String(ext)
    }

    /// The language an extension is written in, for display. Unknown ones show as `.ext`.
    public static func language(_ ext: String) -> String {
        switch ext {
        case "swift": "Swift"
        case "ts", "tsx", "mts", "cts": "TypeScript"
        case "js", "jsx", "mjs", "cjs": "JavaScript"
        case "py", "pyi", "ipynb": "Python"
        case "md", "mdx", "markdown": "Markdown"
        case "json", "jsonl", "jsonc": "JSON"
        case "yml", "yaml": "YAML"
        case "toml": "TOML"
        case "html", "htm": "HTML"
        case "css", "scss", "sass", "less": "CSS"
        case "sh", "bash", "zsh", "fish": "Shell"
        case "rs": "Rust"
        case "go": "Go"
        case "rb", "erb", "gemfile", "rakefile": "Ruby"
        case "java": "Java"
        case "kt", "kts": "Kotlin"
        case "c", "h": "C"
        case "cc", "cpp", "cxx", "hpp", "hh": "C++"
        case "m", "mm": "Objective-C"
        case "cs": "C#"
        case "php": "PHP"
        case "sql": "SQL"
        case "vue": "Vue"
        case "svelte": "Svelte"
        case "dart": "Dart"
        case "ex", "exs": "Elixir"
        case "lua": "Lua"
        case "tf", "hcl": "Terraform"
        case "xml", "plist", "xcstrings": "XML"
        case "txt": "Text"
        case "csv", "tsv": "CSV"
        case "dockerfile": "Dockerfile"
        case "makefile", "justfile": "Makefile"
        case "none": "No extension"
        case "other": "Other"
        default: "." + ext
        }
    }
}
