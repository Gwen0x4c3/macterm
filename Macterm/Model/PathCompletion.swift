import Foundation

/// One entry a path-completion popup can offer: a name in the directory the
/// token's base resolves to, whether it is a directory (its commit drills in),
/// and the text committing it types once the typed prefix is accounted for.
struct PathCompletionCandidate: Equatable {
    let name: String
    let isDirectory: Bool
    /// The full text committing this candidate types, trailing `/` included
    /// for a directory — the drill-down that lists its children next.
    let completionText: String

    init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
        self.completionText = isDirectory ? name + "/" : name
    }
}

/// The parsed shape of the token being typed at the cursor: which directory
/// candidates come from and what they must prefix. Produced by
/// `PathCompletion.query`, consumed by the popup controller.
struct PathCompletionQuery: Equatable {
    /// Absolute, `~`-expanded, `.`/`..`-normalized directory candidates list.
    let baseDirectory: String
    /// The part of the token after its last `/` (empty when the token ended
    /// with one — the drill-down boundary). Candidates prefix-match this,
    /// case-insensitively.
    let typedPrefix: String
}

/// Pure rules for the path-completion popup: which token under the cursor
/// triggers it, which entries it offers, and what committing one types.
/// The popup controller (`PathCompletionPopup.swift`) feeds it the terminal's
/// text and the pane's working directory; everything decidable without a
/// terminal lives here so tests can run it directly.
enum PathCompletion {
    /// The popup never scrolls past this many rows.
    static let maximumCandidates = 50

    /// Commands whose argument is plausibly a path, consulted when the token
    /// carries no `/`. The word immediately before the token must be one of
    /// these — which is also what keeps the popup off command names: whatever
    /// precedes the FIRST word after a prompt is the prompt itself (`❯`,
    /// `user@host`, `➜ macterm git:(main)`), never a command. Subcommand-
    /// heavy tools (git, npm, cargo, docker, …) are deliberately absent:
    /// their argument positions are usually subcommands, and `git st` popping
    /// file suggestions every time costs more than `git add <path>`
    /// completion gains — a token with a slash triggers regardless.
    static let argumentCommands: Set<String> = [
        "cd", "ls", "cat", "less", "more", "head", "tail", "vim", "vi", "nvim",
        "nano", "pico", "emacs", "code", "open", "mkdir", "rmdir", "rm", "cp",
        "mv", "touch", "ln", "chmod", "chown", "chgrp", "stat", "file", "find",
        "fd", "grep", "egrep", "fgrep", "rg", "ag", "sed", "awk", "diff",
        "patch", "tar", "unzip", "zip", "gzip", "gunzip", "bzip2", "xz",
        "source", ".", "du", "md5", "md5sum", "shasum", "strings", "otool",
        "nm", "codesign", "hdiutil", "ditto", "scp", "rsync", "sqlite3", "jq",
        "yq", "ffmpeg", "sips", "convert", "qlmanage", "exa", "eza", "tree",
        "bat", "realpath", "readlink", "basename", "dirname",
    ]

    /// Parse the line the cursor sits on — prompt included, cursor at its
    /// end, exactly what `GhosttyTerminalNSView.readCommandLineBeforeCursor`
    /// returns — into a completion query, or nil when the popup must not
    /// trigger.
    ///
    /// The rules:
    /// - The token is the last whitespace-delimited word. A line ending in
    ///   whitespace means the token is empty: nothing to complete.
    /// - Quoted and option-shaped tokens (`-l`) are refused: their completions
    ///   are not files.
    /// - A token containing `/` is path-shaped and always completes — command
    ///   paths (`./script.sh`, `/usr/bin/foo`) included.
    /// - A bare word completes only when the word before it is a known
    ///   path-taking command; typing a command name or free prose never
    ///   triggers.
    /// - A token containing `=` (an env assignment) never triggers.
    static func query(
        inLine line: String,
        homeDirectory: String,
        workingDirectory: String
    ) -> PathCompletionQuery? {
        if line.hasSuffix(" ") || line.hasSuffix("\t") {
            return nil
        }
        let words = line.split(
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard let token = words.last, !token.isEmpty else { return nil }
        if token.hasPrefix("\"") || token.hasPrefix("'") || token.hasPrefix("`") {
            return nil
        }
        if token.hasPrefix("-"), token.count > 1 {
            return nil
        }
        if token.contains("=") {
            return nil
        }

        let typedPrefix: String
        let rawBase: String
        if let slash = token.lastIndex(of: "/") {
            typedPrefix = String(token[token.index(after: slash)...])
            rawBase = String(token[..<slash])
        } else {
            guard words.count >= 2,
                  argumentCommands.contains(String(words[words.count - 2]))
            else { return nil }
            if token == "~" {
                // A bare `~` drills into the home directory, like a trailing
                // slash would.
                return PathCompletionQuery(baseDirectory: homeDirectory, typedPrefix: "")
            }
            if token.hasPrefix("~") {
                return nil
            } // ~user without a slash
            typedPrefix = String(token)
            rawBase = ""
        }

        guard let base = resolveBase(rawBase, home: homeDirectory, workingDirectory: workingDirectory)
        else { return nil }
        return PathCompletionQuery(baseDirectory: base, typedPrefix: typedPrefix)
    }

    /// Filter and rank a directory listing into what the popup shows, most
    /// wanted first: exact-case prefix matches before case-insensitive ones,
    /// then directories before files (the drill-down target), then
    /// alphabetically. Dotfiles surface only for a dotfile prefix. The result
    /// is capped at `maximumCandidates`.
    static func candidates(for query: PathCompletionQuery, in listing: [PathDirectoryEntry]) -> [PathCompletionCandidate] {
        let prefix = query.typedPrefix
        let foldedPrefix = prefix.lowercased()
        let dotfilePrefix = prefix.hasPrefix(".")
        var exact: [PathCompletionCandidate] = []
        var folded: [PathCompletionCandidate] = []
        for entry in listing {
            if entry.name == "." || entry.name == ".." {
                continue
            }
            if !dotfilePrefix, entry.name.hasPrefix(".") {
                continue
            }
            let candidate = PathCompletionCandidate(name: entry.name, isDirectory: entry.isDirectory)
            if entry.name.hasPrefix(prefix) {
                exact.append(candidate)
            } else if entry.name.lowercased().hasPrefix(foldedPrefix) {
                folded.append(candidate)
            }
        }
        func rank(_ a: PathCompletionCandidate, _ b: PathCompletionCandidate) -> Bool {
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        exact.sort(by: rank)
        folded.sort(by: rank)
        return Array((exact + folded).prefix(maximumCandidates))
    }

    /// What committing `candidate` types: the number of typed prefix
    /// characters to erase first, then the text to type. A candidate whose
    /// name extends the typed text case-sensitively appends only its tail;
    /// a case-insensitive match whose casing differs must rewrite the word,
    /// because the filesystem entry is the spelling that will be opened.
    static func insertion(for candidate: PathCompletionCandidate, typedPrefix: String) -> (erase: Int, text: String) {
        if candidate.completionText.hasPrefix(typedPrefix) {
            return (0, String(candidate.completionText.dropFirst(typedPrefix.count)))
        }
        return (typedPrefix.count, candidate.completionText)
    }

    /// Resolve a token's base — everything before its last `/` — against the
    /// pane's working directory. `~` expands to the home directory; `~user`
    /// is refused (another account's home is not ours to guess); relative
    /// bases, `./` and `../` included, join the working directory and
    /// normalize lexically, the way the shell resolves them for a non-symlink
    /// path.
    static func resolveBase(_ rawBase: String, home: String, workingDirectory: String) -> String? {
        if rawBase.isEmpty {
            return workingDirectory
        }
        var expanded = rawBase
        if expanded == "~" {
            return home
        }
        if expanded.hasPrefix("~/") {
            expanded = home + expanded.dropFirst()
        } else if expanded.hasPrefix("~") {
            return nil
        }
        if !expanded.hasPrefix("/") {
            expanded = (workingDirectory as NSString).appendingPathComponent(expanded)
        }
        return (expanded as NSString).standardizingPath
    }
}

/// One row of a raw directory listing — a value type so the listing can be
/// read off the main-thread-unsafe `FileManager` call on a background queue
/// and ranked on the main actor.
struct PathDirectoryEntry: Equatable, Sendable {
    let name: String
    let isDirectory: Bool
}

extension PathCompletion {
    /// Read a directory's entries off disk, `nil` when the path is not a
    /// readable directory (the popup's fail-closed: no listing, no popup).
    /// Called off-main; ranking happens on the main actor.
    static func directoryEntries(at path: String) -> [PathDirectoryEntry]? {
        let url = URL(fileURLWithPath: path)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        else { return nil }
        return urls.map { entry in
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return PathDirectoryEntry(name: entry.lastPathComponent, isDirectory: isDirectory)
        }
    }
}
