<!-- page:
slug: path-completion
title: Path Completion
nav: Path Completion
group: Everyday use
description: While you type a path at a shell prompt, Macterm suggests the matching files and folders in a picker at the cursor.
-->

# Path Completion

While a shell prompt is showing, typing a path offers the matching files and folders in a picker anchored at your cursor — like an IDE's autocomplete, but for the terminal. Type `cd ass` and Macterm lists what matches `ass` in the pane's working directory.

## Using it

- **Keep typing** to narrow the list; the picker follows the token under the cursor and updates after every keystroke.
- **↑ / ↓** move the selection (it wraps). **Shift-Tab** moves back.
- **Tab** inserts the selected entry. Directories insert with a trailing `/` and the picker immediately lists their contents, so `cd as` → Tab → Tab walks you into `assets/`.
- **Return** never rewrites a line you meant to run: it descends into a selected directory that still has characters to add, and otherwise passes through to the shell. After a descent, the next Return runs the line.
- **Click** a row to insert it directly — including files.
- **Esc** dismisses the picker; a click in the terminal, or moving the cursor with ←/→, dismisses it too.

Suggestions come from the pane's actual working directory (the shell's own, followed live — `cd` elsewhere and the picker follows), with `~`, `./` and `../` prefixes resolved the way the shell would. Case differences are forgiven; committing rewrites the word when the real file's spelling differs.

## When it appears

Only while a shell owns the line — never over a running program or a TUI — and only for tokens that look like paths: any token containing `/`, or a plain word after a command that takes files (`cd`, `vim`, `grep`, …). Typing a command name, a flag, or free prose never triggers it. Local panes only; remote projects are not listed.

Turn it off in **Settings → General → Completion**.
