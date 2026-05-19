# claude-statusline

A custom status line for [Claude Code CLI](https://claude.ai/code) that shows git branch, model, context window usage, and rate limit usage with reset countdowns.

```
feature/my-branch  Sonnet 4.6  ctx:37%  5h:28%(27m)  7d:9%(4d0h)
```

## What it shows

| Segment | Description |
|---|---|
| `feature/my-branch` | Current git branch of the working directory |
| `Sonnet 4.6` | Active model |
| `ctx:37%` | Context window used (green → yellow at 60% → red at 80%) |
| `5h:28%(27m)` | 5-hour session usage + time until reset |
| `7d:9%(4d0h)` | Weekly usage + time until reset |

Rate limit segments are color-coded: green below 60%, yellow 60–79%, red 80%+. Reset countdowns are shown in dimmed text.

## Installation

### Windows (PowerShell 7+)

1. Copy `statusline.ps1` somewhere permanent, e.g. `C:\Users\<you>\.claude\statusline.ps1`
2. Add to `%USERPROFILE%\.claude\settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "pwsh -NoProfile -File C:/Users/<you>/.claude/statusline.ps1"
  }
}
```

### macOS / Linux (bash + jq)

Requires `jq` and `git` on `PATH`.

1. Copy `statusline.sh` somewhere permanent, e.g. `~/.claude/statusline.sh`
2. Make it executable:
   ```bash
   chmod +x ~/.claude/statusline.sh
   ```
3. Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/<you>/.claude/statusline.sh"
  }
}
```

## Requirements

| Platform | Requirements |
|---|---|
| Windows | PowerShell 7+ (`pwsh`), `git` on PATH |
| macOS / Linux | bash, `jq`, `git` on PATH |

## Notes

- Rate limit data (`5h`, `7d`) only appears after the first API response in a session — it is absent for Pro/Max subscribers when no limits have been hit yet.
- The `resets_at` timestamp is provided by Claude Code and may take a turn or two to stabilise to the exact reset time.
- The status line is updated by Claude Code after each turn, not on a real-time ticker.
