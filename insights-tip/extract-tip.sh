#!/usr/bin/env bash
# Sourced by statusline.sh. Defines get_insights_tip <now_epoch> which echoes
# the formatted tip line (e.g. "tip #5: ...  (/tip 5 for details)") or empty.
# Maintains ~/.claude/statusline-tip.json as a catalog of all tips from the
# latest /insights report (1h TTL, rotation by epoch_hour). Auto-installs
# ~/.claude/commands/tip.md unless ~/.claude/commands/.tip-uninstalled exists.

_html_decode() {
  echo "$1" | sed -e "s|&apos;|'|g" -e 's|&amp;|\&|g' -e 's|&quot;|"|g' -e 's|&lt;|<|g' -e 's|&gt;|>|g'
}

_install_tip_command() {
  local cmd_dir="$HOME/.claude/commands"
  local cmd_file="$cmd_dir/tip.md"
  local marker="$cmd_dir/.tip-uninstalled"
  [ -f "$marker" ] && return
  [ -f "$cmd_file" ] && return
  mkdir -p "$cmd_dir" 2>/dev/null || return
  cat > "$cmd_file" <<'EOF'
---
description: Show full details of the current statusline tip
argument-hint: [tip number, e.g. 5]
---

Read the file at `$HOME/.claude/statusline-tip.json` (on Windows: `$env:USERPROFILE\.claude\statusline-tip.json`). The user invoked `/tip` with argument: `$ARGUMENTS`

- If the argument is empty, find the tip in the `tips` array whose `index` equals the top-level `current_tip_index` field.
- If the argument is a number, find the tip in the `tips` array whose `index` equals that number.
- If no matching tip exists, respond with exactly: `No such tip — valid range is 1 to <N>` where `<N>` is the highest `index` in the `tips` array.

Print only the `details` field of the matched tip (or the error message above) as a plain string. Do not add headers, code fences, surrounding commentary, or other formatting.
EOF
}

# Sets caller's _current_tip_index and _current_tip_text via dynamic scoping.
_build_tip_catalog() {
  local report=$1 now=$2 tip_file=$3

  local md_titles=() md_whys=()
  while IFS= read -r line; do
    [ -n "$line" ] && md_titles+=("$line")
  done < <(grep -oE '<code class="cmd-code">## [^<]+' "$report" 2>/dev/null | sed 's|<code class="cmd-code">## ||')
  while IFS= read -r line; do
    [ -n "$line" ] && md_whys+=("$line")
  done < <(grep -oE '<div class="cmd-why">[^<]+' "$report" 2>/dev/null | sed 's|<div class="cmd-why">||')

  local pat_titles=() pat_summs=() pat_dets=()
  while IFS= read -r line; do
    [ -n "$line" ] && pat_titles+=("$line")
  done < <(grep -oE '<div class="pattern-title">[^<]+' "$report" 2>/dev/null | sed 's|<div class="pattern-title">||')
  while IFS= read -r line; do
    [ -n "$line" ] && pat_summs+=("$line")
  done < <(grep -oE '<div class="pattern-summary">[^<]+' "$report" 2>/dev/null | sed 's|<div class="pattern-summary">||')
  while IFS= read -r line; do
    [ -n "$line" ] && pat_dets+=("$line")
  done < <(grep -oE '<div class="pattern-detail">[^<]+' "$report" 2>/dev/null | sed 's|<div class="pattern-detail">||')

  local n_md=${#md_titles[@]}
  [ $n_md -gt ${#md_whys[@]} ] && n_md=${#md_whys[@]}
  local n_pat=${#pat_titles[@]}
  [ $n_pat -gt ${#pat_summs[@]} ] && n_pat=${#pat_summs[@]}
  [ $n_pat -gt ${#pat_dets[@]} ] && n_pat=${#pat_dets[@]}

  local tips_json="["
  local sep=""
  local idx=0
  local i text details obj
  for ((i=0; i<n_md; i++)); do
    idx=$((idx + 1))
    text="claude.md: ${md_titles[$i]}"
    details="${md_whys[$i]}"
    text=$(_html_decode "$text")
    details=$(_html_decode "$details")
    obj=$(jq -n --argjson idx $idx --arg t "$text" --arg d "$details" '{index:$idx, text:$t, details:$d}')
    tips_json="${tips_json}${sep}${obj}"
    sep=","
  done
  for ((i=0; i<n_pat; i++)); do
    idx=$((idx + 1))
    text="pattern: ${pat_titles[$i]}"
    details="${pat_summs[$i]} ${pat_dets[$i]}"
    if [ ${#details} -gt 400 ]; then
      details="${details:0:397}..."
    fi
    text=$(_html_decode "$text")
    details=$(_html_decode "$details")
    obj=$(jq -n --argjson idx $idx --arg t "$text" --arg d "$details" '{index:$idx, text:$t, details:$d}')
    tips_json="${tips_json}${sep}${obj}"
    sep=","
  done
  tips_json="${tips_json}]"

  [ $idx -gt 0 ] || return 1

  local epoch_hour=$(( now / 3600 ))
  local current_idx=$(( (epoch_hour % idx) + 1 ))
  local exp=$(( now + 3600 ))
  local src
  src=$(basename "$report")

  jq -n \
    --argjson cur $current_idx \
    --argjson exp $exp \
    --arg src "$src" \
    --argjson gen $now \
    --argjson tips "$tips_json" \
    '{current_tip_index:$cur, expires_at:$exp, source_report:$src, generated_at:$gen, tips:$tips}' \
    > "$tip_file" 2>/dev/null

  _current_tip_index=$current_idx
  _current_tip_text=$(echo "$tips_json" | jq -r --argjson cur $current_idx '.[$cur-1].text')
}

get_insights_tip() {
  local now=$1
  local tip_file="$HOME/.claude/statusline-tip.json"

  if [ -f "$tip_file" ]; then
    local cached_exp
    cached_exp=$(jq -r '.expires_at // empty' "$tip_file" 2>/dev/null)
    if [ -n "$cached_exp" ] && [ "$cached_exp" -gt "$now" ] 2>/dev/null; then
      local idx text
      idx=$(jq -r '.current_tip_index // empty' "$tip_file" 2>/dev/null)
      if [ -n "$idx" ]; then
        text=$(jq -r --argjson i "$idx" '.tips[] | select(.index == $i) | .text' "$tip_file" 2>/dev/null)
        if [ -n "$text" ]; then
          echo "tip #${idx}: ${text}  (/tip ${idx} for details)"
          return
        fi
      fi
    fi
  fi

  local usage_dir="$HOME/.claude/usage-data"
  local report
  report=$(ls -1t "$usage_dir"/report-*.html 2>/dev/null | head -1)
  [ -n "$report" ] && [ -f "$report" ] || return

  local _current_tip_index _current_tip_text
  _build_tip_catalog "$report" "$now" "$tip_file" || return

  _install_tip_command

  echo "tip #${_current_tip_index}: ${_current_tip_text}  (/tip ${_current_tip_index} for details)"
}
