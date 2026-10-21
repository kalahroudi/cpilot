# Roadmap

Ideas we want to build, not promises. Newest first.

## Local CI

Run a branch's GitHub workflows on your own machine before pushing, from the pull request and session screens.

- **A "Run CI locally" card** listing the jobs in `.github/workflows` for the branch you are on, with each job's runner type.
- **Linux jobs** run through [act](https://github.com/nektos/act) on Colima, in a throwaway worktree so your working folder is untouched. CPilot points act at Colima's Docker socket (`~/.colima/default/docker.sock`) and streams the log live.
- **macOS jobs** (`runs-on: macos-*`) cannot run in a Linux container, so CPilot runs the job's `run:` steps natively in the same throwaway worktree. Steps that use a marketplace action other than checkout are skipped and listed.
- **Failures** offer "Fix it", which starts a session with the failing log.

Limits to design around:

- A local macOS run uses your Mac's Swift and Xcode, not the GitHub runner image, so a pass is a good sign and not a guarantee.
- Secrets and most `uses:` actions are not available locally.
- The result is informational. It does not replace GitHub's checks in the merge gate.

Already in place: `act` and Colima are installed on the maintainer's machine, and CPilot already has a place on the pull request screen for per-PR checks.
