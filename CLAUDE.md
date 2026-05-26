# claude-statusline

Custom status line scripts for Claude Code CLI showing git repo/branch, model, context usage, and rate limit countdowns.

## Repo structure

- `statusline.ps1` — Windows PowerShell 7+ implementation
- `statusline.sh` — macOS/Linux bash implementation (requires `jq` and `git`)
- `insights-tip/extract-tip.ps1` / `extract-tip.sh` — helper sourced by the statusline to build the tip catalog and produce the hourly `tip #N` line; also auto-installs `commands/tip.md` into `~/.claude/commands/`
- `commands/tip.md` — source-of-truth for the `/tip` custom slash command (the file the helpers write to `~/.claude/commands/`)
- `settings-example.json` — Example Claude Code settings snippet
- `README.md` — Installation and usage docs

## Key rules

- **Always keep `.ps1` and `.sh` in sync.** Any feature added to one must be added to the other. They must stay functionally equivalent.
- **Update `README.md`** whenever the status bar output format or segments change — including the example output line and the "What it shows" table.
- The live installed script for this machine is at `C:\Users\lasith\.claude\statusline-command.ps1`. When testing changes, update that file first, let the user verify, then apply the same change to the repo files.
