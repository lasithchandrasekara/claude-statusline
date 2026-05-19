# Git Status Second Line — Design Spec

**Date:** 2026-05-19
**Status:** Approved

## Summary

Add a second line to the Claude Code statusline showing git working-tree status. The line only appears when there is something to report; a clean repo shows nothing.

## Output Format

```
reponame/branch  Model  ctx:%  5h:%  7d:%
* ↑2 ↓1 ~2
```

Each segment is omitted when its value is zero or unavailable.

## Segments

| Symbol | Meaning | Color | Condition |
|---|---|---|---|
| `*` | Uncommitted changes (modified, staged, or untracked files) | yellow | `git status --porcelain` returns non-empty output |
| `↑N` | Commits ahead of remote tracking branch | cyan | N > 0 |
| `↓N` | Commits behind remote tracking branch | cyan | N > 0 |
| `~N` | Number of stash entries | dim | N > 0 |

If all four values are zero/absent, the second line is suppressed entirely.

## Implementation

### Dirty check
```
git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null
```
Non-empty output → show `*`.

### Ahead/behind
```
git -C "$cwd" --no-optional-locks rev-list --left-right --count HEAD...@{u} 2>/dev/null
```
Returns two numbers: `ahead behind`. Silently skipped if no upstream tracking branch is configured.

### Stash count
```
git -C "$cwd" --no-optional-locks stash list 2>/dev/null | wc -l
```

### Output line
In PowerShell, use `[Console]::Write` with a newline prefix if the second line is non-empty. In bash, use `printf "\n%s"`.

## Files Changed

| File | Change |
|---|---|
| `C:\Users\lasith\.claude\statusline-command.ps1` | Updated first for live verification |
| `statusline.ps1` | Same change applied after user confirms |
| `statusline.sh` | Equivalent bash implementation |

## Out of Scope

- File-count in the dirty indicator (e.g. `*3`) — kept as plain `*` for compactness
- Clean state indicator (e.g. `✔ clean`) — second line hidden when clean
- Untracked-only vs staged distinction — all dirty states collapse to `*`
