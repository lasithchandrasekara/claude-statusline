#!/usr/bin/env bash
input=$(cat)

reset="\033[0m"
cyan="\033[36m"
yellow="\033[33m"
red="\033[31m"
green="\033[32m"
white="\033[37m"
dim="\033[2m"

format_time_remaining() {
  local secs=$1
  if [ "$secs" -le 0 ] 2>/dev/null; then echo "now"; return; fi
  local d=$(( secs / 86400 ))
  local h=$(( (secs % 86400) / 3600 ))
  local m=$(( (secs % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then echo "${d}d${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h${m}m"
  else echo "${m}m"
  fi
}

now=$(date -u +%s)

model=$(echo "$input" | jq -r '.model.display_name // "Unknown model"')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_resets_at=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_resets_at=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')

git_branch=""
git_repo=""
if [ -n "$cwd" ]; then
  git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  git_toplevel=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$git_toplevel" ]; then
    git_repo=$(basename "$git_toplevel")
  fi
fi

parts=""

# Current working directory (shortened)
if [ -n "$cwd" ]; then
  display_path=$(echo "$cwd" | sed "s|^$HOME|~|")
  parts="${parts}$(printf "${dim}%s${reset}" "$display_path")  "
fi

# Git repo name, branch, and inline status
if [ -n "$git_repo" ] && [ -n "$git_branch" ]; then
  parts="${parts}$(printf "${cyan}%s/%s${reset}" "$git_repo" "$git_branch")  "
elif [ -n "$git_branch" ]; then
  parts="${parts}$(printf "${cyan}%s${reset}" "$git_branch")  "
elif [ -n "$git_repo" ]; then
  parts="${parts}$(printf "${cyan}%s${reset}" "$git_repo")  "
fi

if [ -n "$cwd" ]; then
  if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
    parts="${parts}$(printf "${yellow}*${reset}")  "
  fi
  ab=$(git -C "$cwd" --no-optional-locks rev-list --left-right --count "HEAD...@{u}" 2>/dev/null)
  if [ -n "$ab" ]; then
    git_ahead=$(echo "$ab" | awk '{print $1}')
    git_behind=$(echo "$ab" | awk '{print $2}')
    if [ "${git_ahead:-0}" -gt 0 ] 2>/dev/null; then
      parts="${parts}$(printf "${cyan}+%s${reset}" "$git_ahead")  "
    fi
    if [ "${git_behind:-0}" -gt 0 ] 2>/dev/null; then
      parts="${parts}$(printf "${cyan}-%s${reset}" "$git_behind")  "
    fi
  fi
  stash_count=$(git -C "$cwd" --no-optional-locks stash list 2>/dev/null | wc -l | tr -d ' ')
  if [ "${stash_count:-0}" -gt 0 ] 2>/dev/null; then
    parts="${parts}$(printf "${dim}~%s${reset}" "$stash_count")  "
  fi
fi

# Model name
parts="${parts}$(printf "${white}%s${reset}" "$model")  "

# Context %
if [ -n "$used_pct" ]; then
  used_int=${used_pct%.*}
  if [ "$used_int" -ge 80 ] 2>/dev/null; then ctx_color="$red"
  elif [ "$used_int" -ge 60 ] 2>/dev/null; then ctx_color="$yellow"
  else ctx_color="$green"
  fi
  parts="${parts}$(printf "ctx:${ctx_color}%.0f%%${reset}" "$used_pct")  "
fi

# 5-hour session usage
if [ -n "$five_hour_pct" ]; then
  five_int=${five_hour_pct%.*}
  if [ "$five_int" -ge 80 ] 2>/dev/null; then s_color="$red"
  elif [ "$five_int" -ge 60 ] 2>/dev/null; then s_color="$yellow"
  else s_color="$green"
  fi
  part=$(printf "5h:${s_color}%.0f%%${reset}" "$five_hour_pct")
  if [ -n "$five_resets_at" ]; then
    remaining=$(( five_resets_at - now ))
    part="${part}$(printf "${dim}(%s)${reset}" "$(format_time_remaining "$remaining")")"
  fi
  parts="${parts}${part}  "
fi

# 7-day weekly usage
if [ -n "$seven_day_pct" ]; then
  seven_int=${seven_day_pct%.*}
  if [ "$seven_int" -ge 80 ] 2>/dev/null; then w_color="$red"
  elif [ "$seven_int" -ge 60 ] 2>/dev/null; then w_color="$yellow"
  else w_color="$green"
  fi
  part=$(printf "7d:${w_color}%.0f%%${reset}" "$seven_day_pct")
  if [ -n "$seven_resets_at" ]; then
    remaining=$(( seven_resets_at - now ))
    part="${part}$(printf "${dim}(%s)${reset}" "$(format_time_remaining "$remaining")")"
  fi
  parts="${parts}${part}  "
fi

# Other Claude sessions (waiting or busy, excluding this one) — one per line
my_parent_pid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')
session_dir="$HOME/.claude/sessions"
session_lines=""
if [ -d "$session_dir" ]; then
  for f in "$session_dir"/*.json; do
    [ -f "$f" ] || continue
    s_pid=$(jq -r '.pid // empty' "$f" 2>/dev/null)
    s_status=$(jq -r '.status // empty' "$f" 2>/dev/null)
    s_name=$(jq -r '.name // empty' "$f" 2>/dev/null | tr -d '"')
    [ "$s_pid" = "$my_parent_pid" ] && continue
    [ "$s_status" = "waiting" ] || [ "$s_status" = "busy" ] || continue
    kill -0 "$s_pid" 2>/dev/null || continue
    [ -z "$s_name" ] && s_name="unnamed"
    if [ "$s_status" = "waiting" ]; then
      session_lines="${session_lines}
$(printf "${yellow}? %s${reset}" "$s_name")"
    else
      session_lines="${session_lines}
$(printf "${dim}> %s${reset}" "$s_name")"
    fi
  done
fi

output="${parts%  }"
if [ -n "$session_lines" ]; then
  output="${output}${session_lines}"
fi
printf "%s" "$output"
