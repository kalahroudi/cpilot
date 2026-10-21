// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A single text-in, text-out call to Claude for small jobs (a recap, a pull request description, a note draft).
/// It uses the small model, no tools, and leaves no session behind in the user's history.
public enum ClaudeOneShot {
    public static func arguments(prompt: String, model: String = "haiku") -> [String] {
        ["-p", "--model", model, "--no-session-persistence", "--tools=", prompt]
    }

    public static func run(_ prompt: String, in folder: String, model: String = "haiku", timeout: TimeInterval = 90) async -> String? {
        guard let out = try? await Shell.check("claude", arguments(prompt: prompt, model: model), cwd: URL(fileURLWithPath: folder), timeout: timeout) else { return nil }
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
