import Foundation
import AppKit

/// Hands a prompt to Claude Code in a new Terminal window.
///
/// Written as a `.command` file and opened with Terminal rather than driven by
/// AppleScript: `open` needs no Automation permission, and the user ends up in a
/// normal interactive session where Claude Code asks before it runs anything.
enum ClaudeLauncher {
    static func run(prompt: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("performance-hud-claude", isDirectory: true)
        let id = UUID().uuidString
        let promptFile = dir.appendingPathComponent("\(id).txt")
        let script = dir.appendingPathComponent("\(id).command")

        // The prompt goes in a file and is read back by the shell, so nothing in
        // it (quotes, backticks, `$`) ever needs escaping.
        let body = """
        #!/bin/zsh
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        cd "$HOME"
        clear
        if ! command -v claude >/dev/null 2>&1; then
          echo "Claude Code isn't installed (no 'claude' on PATH)."
          echo "Install it from https://claude.com/claude-code and try again."
          rm -f "\(promptFile.path)" "\(script.path)"
          exit 1
        fi
        PROMPT="$(cat "\(promptFile.path)")"
        rm -f "\(promptFile.path)" "\(script.path)"
        exec claude "$PROMPT"
        """

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try prompt.write(to: promptFile, atomically: true, encoding: .utf8)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            return
        }

        NSWorkspace.shared.open([script],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
