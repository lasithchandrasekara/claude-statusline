---
description: Show full details of the current statusline tip
argument-hint: [tip number, e.g. 5]
---

Read the file at `$HOME/.claude/statusline-tip.json` (on Windows: `$env:USERPROFILE\.claude\statusline-tip.json`). The user invoked `/tip` with argument: `$ARGUMENTS`

- If the argument is empty, find the tip in the `tips` array whose `index` equals the top-level `current_tip_index` field.
- If the argument is a number, find the tip in the `tips` array whose `index` equals that number.
- If no matching tip exists, respond with exactly: `No such tip — valid range is 1 to <N>` where `<N>` is the highest `index` in the `tips` array.

Print only the `details` field of the matched tip (or the error message above) as a plain string. Do not add headers, code fences, surrounding commentary, or other formatting.
