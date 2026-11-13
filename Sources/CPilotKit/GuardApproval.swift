// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Some repositories refuse a commit that touches protected files until a person has looked at the staged diff and run an approval script (for example `pnpm guard:approve`),
/// which records the approval in a lock file that is committed with the change. Every task worktree needs its own. These are the pure parts of handling them all in one place.
public enum GuardApproval {
    /// The script that records a person's approval: one that names both a guard and an approval first, then any approval. Nil when the worktree has none.
    public static func approveScript(_ found: [ProjectScripts.Found]) -> (found: ProjectScripts.Found, script: String)? {
        for pass in 0..<2 {
            for f in found {
                if let s = f.scripts.sorted().first(where: { n in let l = n.lowercased(); return l.contains("approve") && (pass == 1 || l.contains("guard")) }) { return (f, s) }
            }
        }
        return nil
    }

    /// The tool and arguments that run a script, split for `Shell.run` (never joined into a shell line).
    public static func invocation(_ found: ProjectScripts.Found, _ script: String) -> (tool: String, args: [String]) {
        switch found.runner {
        case "make", "just": return (found.runner, [script])
        default: return (found.runner, ["run", script])
        }
    }

    /// What approving writes: lock files the script updates. After approval these are staged with the change, and nothing else is.
    public static func lockFilesToStage(_ status: GitStatusSummary) -> [String] {
        (status.unstaged + status.untracked).filter { p in
            let name = (p as NSString).lastPathComponent.lowercased()
            return name.hasSuffix(".json") && name.contains("guard") && name.contains("lock")
        }
    }

    public static func suggestedMessage(taskId: String?, title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return taskId.map { "\($0): \(t)" } ?? t
    }

    /// A worktree is waiting for approval when it has staged changes and a script that records one.
    public static func waiting(status: GitStatusSummary, scripts: [ProjectScripts.Found]) -> Bool {
        !status.staged.isEmpty && approveScript(scripts) != nil
    }
}
