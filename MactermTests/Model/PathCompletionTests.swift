import Foundation
@testable import Macterm
import Testing

struct PathCompletionTests {
    private let home = "/Users/tester"
    private let workingDirectory = "/Users/tester/dev/macterm"

    private func query(_ line: String) -> PathCompletionQuery? {
        PathCompletion.query(inLine: line, homeDirectory: home, workingDirectory: workingDirectory)
    }

    // MARK: - Trigger

    @Test
    func bare_token_after_path_taking_command_triggers() {
        // The prompt glyphs ahead of the command don't matter: the popup keys
        // off the word immediately before the token.
        #expect(query("❯ cd as") == PathCompletionQuery(
            baseDirectory: workingDirectory, typedPrefix: "as"
        ))
        #expect(query("user@mac ~ % cd as") == PathCompletionQuery(
            baseDirectory: workingDirectory, typedPrefix: "as"
        ))
        #expect(query("cat RE") == PathCompletionQuery(
            baseDirectory: workingDirectory, typedPrefix: "RE"
        ))
    }

    @Test
    func token_with_slash_triggers_without_a_command() {
        // `./script.sh` completes its own directory; the first word after a
        // prompt may legitimately be a path.
        #expect(query("./sc") == PathCompletionQuery(
            baseDirectory: workingDirectory, typedPrefix: "sc"
        ))
        #expect(query("❯ /usr/lo") == PathCompletionQuery(
            baseDirectory: "/usr", typedPrefix: "lo"
        ))
    }

    @Test
    func command_name_typing_does_not_trigger() {
        // The word before the first word after the prompt is the prompt
        // itself, never a command.
        #expect(query("cd") == nil)
        #expect(query("❯ cd") == nil)
        #expect(query("❯ git st") == nil)
        #expect(query("echo hel") == nil)
    }

    @Test
    func quoted_option_and_env_tokens_do_not_trigger() {
        #expect(query("cd 'as") == nil)
        #expect(query("cd \"as") == nil)
        #expect(query("ls -l") == nil)
        #expect(query("export FOO=bar") == nil)
    }

    @Test
    func empty_token_does_not_trigger() {
        #expect(query("") == nil)
        #expect(query("❯") == nil)
        #expect(query("❯ cd ") == nil)
        #expect(query("❯ cd\t") == nil)
    }

    // MARK: - Base resolution

    @Test
    func home_tilde_expands() {
        #expect(query("❯ cd ~/Do") == PathCompletionQuery(
            baseDirectory: home, typedPrefix: "Do"
        ))
        #expect(query("❯ cd ~") == PathCompletionQuery(
            baseDirectory: home, typedPrefix: ""
        ))
    }

    @Test
    func user_tilde_is_refused() {
        #expect(query("❯ cd ~other/Do") == nil)
    }

    @Test
    func dot_and_dotdot_normalize_lexically() {
        #expect(query("❯ cd ./Mo") == PathCompletionQuery(
            baseDirectory: workingDirectory, typedPrefix: "Mo"
        ))
        #expect(query("❯ cd ../macterm/Ma") == PathCompletionQuery(
            baseDirectory: "/Users/tester/dev/macterm", typedPrefix: "Ma"
        ))
        #expect(query("❯ cd dev/../Mo") == PathCompletionQuery(
            baseDirectory: workingDirectory, typedPrefix: "Mo"
        ))
    }

    @Test
    func trailing_slash_lists_the_whole_directory() {
        // The drill-down boundary: committing `assets/` re-lists its children.
        #expect(query("❯ cd ass/") == PathCompletionQuery(
            baseDirectory: workingDirectory + "/ass", typedPrefix: ""
        ))
    }

    // MARK: - Candidates

    static let listing: [PathDirectoryEntry] = [
        PathDirectoryEntry(name: "assets", isDirectory: true),
        PathDirectoryEntry(name: "Assistant.swift", isDirectory: false),
        PathDirectoryEntry(name: "ASSETS.md", isDirectory: false),
        PathDirectoryEntry(name: "bin", isDirectory: true),
        PathDirectoryEntry(name: ".git", isDirectory: true),
        PathDirectoryEntry(name: ".github", isDirectory: true),
        PathDirectoryEntry(name: "Package.swift", isDirectory: false),
    ]

    private func candidates(_ prefix: String, in listing: [PathDirectoryEntry] = Self.listing) -> [PathCompletionCandidate] {
        PathCompletion.candidates(
            for: PathCompletionQuery(baseDirectory: workingDirectory, typedPrefix: prefix),
            in: listing
        )
    }

    @Test
    func prefix_match_is_case_insensitive_and_ranked() {
        // Exact-case matches first, then case-insensitive ones alphabetical:
        // "assets" is the exact-case prefix, the other two fold to it.
        let names = candidates("as").map(\.name)
        #expect(names == ["assets", "ASSETS.md", "Assistant.swift"])
    }

    @Test
    func dotfiles_surfaces_only_for_a_dotfile_prefix() {
        #expect(!candidates("a").map(\.name).contains(".git"))
        #expect(candidates(".").map(\.name) == [".git", ".github"])
        #expect(candidates(".gi").map(\.name) == [".git", ".github"])
    }

    @Test
    func empty_prefix_lists_everything_except_dotfiles() {
        let names = candidates("").map(\.name)
        #expect(names.contains("assets"))
        #expect(names.contains("bin"))
        #expect(!names.contains(".git"))
    }

    @Test
    func directories_precede_files_within_a_match_class() {
        let listing: [PathDirectoryEntry] = [
            PathDirectoryEntry(name: "alpha-file", isDirectory: false),
            PathDirectoryEntry(name: "alpha-dir", isDirectory: true),
        ]
        #expect(candidates("alpha", in: listing).map(\.name) == ["alpha-dir", "alpha-file"])
    }

    @Test
    func candidates_are_capped() {
        let listing = (0 ..< 200).map { PathDirectoryEntry(name: "entry\($0)", isDirectory: false) }
        #expect(candidates("entry", in: listing).count == PathCompletion.maximumCandidates)
    }

    // MARK: - Insertion

    @Test
    func commit_appends_the_case_matched_tail() {
        let plan = PathCompletion.insertion(
            for: PathCompletionCandidate(name: "assets", isDirectory: true),
            typedPrefix: "as"
        )
        #expect(plan == (0, "sets/"))
    }

    @Test
    func commit_rewrites_when_the_casing_differs() {
        // The filesystem spelling is the one that will be opened, so a
        // case-insensitive match whose casing differs erases the typed word.
        let plan = PathCompletion.insertion(
            for: PathCompletionCandidate(name: "Assistant.swift", isDirectory: false),
            typedPrefix: "as"
        )
        #expect(plan == (2, "Assistant.swift"))
    }

    @Test
    func commit_of_a_fully_typed_file_adds_nothing() {
        // This is the case where Return must pass through to the shell.
        let plan = PathCompletion.insertion(
            for: PathCompletionCandidate(name: "assets", isDirectory: false),
            typedPrefix: "assets"
        )
        #expect(plan == (0, ""))
    }
}
