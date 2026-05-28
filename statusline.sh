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

_visible_len() {
  local esc stripped
  esc=$(printf '\033')
  stripped=$(printf '%s' "$1" | sed "s/${esc}\[[0-9;]*m//g")
  printf '%s' "${#stripped}"
}

# Width budget for row 1. Terminal width can't be detected in the statusline
# spawn, so this is a fixed value: $STATUSLINE_MAX_WIDTH if set, else 200.
_width_budget() {
  if [ -n "$STATUSLINE_MAX_WIDTH" ] && [ "$STATUSLINE_MAX_WIDTH" -gt 0 ] 2>/dev/null; then
    printf '%s' "$STATUSLINE_MAX_WIDTH"; return
  fi
  printf '%s' "200"
}

# Drop whole middle directory segments (keep root + leaf) until path fits $target.
_compress_folder() {
  local path=$1 target=$2
  local IFS='/'
  local segs=($path)
  local n=${#segs[@]}
  if [ "$n" -le 2 ]; then printf '%s' "$path"; return; fi
  local last="${segs[$((n-1))]}"
  local keep candidate prefix
  for ((keep=n-1; keep>=1; keep--)); do
    if [ "$keep" -ge "$((n-1))" ]; then
      candidate="$path"
    else
      prefix="${segs[*]:0:keep}"
      candidate="${prefix}/.../${last}"
    fi
    if [ "${#candidate}" -le "$target" ]; then printf '%s' "$candidate"; return; fi
  done
  printf '%s' "${segs[0]}/.../${last}"
}

# Trim branch tail, append "...", 20-char floor so type/ticket prefix survives.
_compress_branch() {
  local branch=$1 target=$2
  if [ "${#branch}" -le "$target" ]; then printf '%s' "$branch"; return; fi
  local keep=$((target - 3))
  [ "$keep" -lt 20 ] && keep=20
  if [ "$keep" -ge "${#branch}" ]; then printf '%s' "$branch"; return; fi
  printf '%s' "${branch:0:keep}..."
}

now=$(date -u +%s)

model=$(echo "$input" | jq -r '.model.display_name // "Unknown model"')
effort=$(echo "$input" | jq -r '.effort.level // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
used_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_resets_at=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_resets_at=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
total_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // empty')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // empty')
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

# Model + effort level
model_str=$(printf "${white}%s${reset}" "$model")
if [ -n "$effort" ] && [ "$effort" != "normal" ]; then
  model_str="${model_str}  $(printf "${dim}effort:%s${reset}" "$effort")"
fi
parts="${parts}${model_str}  "

# Context % with token count
if [ -n "$used_pct" ]; then
  used_int=${used_pct%.*}
  if [ "$used_int" -ge 80 ] 2>/dev/null; then ctx_color="$red"
  elif [ "$used_int" -ge 60 ] 2>/dev/null; then ctx_color="$yellow"
  else ctx_color="$green"
  fi
  token_str=""
  if [ -n "$used_tokens" ] && [ -n "$ctx_size" ]; then
    used_k=$(( (used_tokens + 500) / 1000 ))
    size_k=$(( (ctx_size + 500) / 1000 ))
    token_str="$(printf "${dim}(%sk/%sk)${reset}" "$used_k" "$size_k")"
  fi
  parts="${parts}$(printf "ctx:${ctx_color}%.0f%%${reset}" "$used_pct")${token_str}  "
fi

# Session cost and lines changed
if [ -n "$total_cost" ]; then
  cost_fmt=$(printf "%.2f" "$total_cost")
  parts="${parts}$(printf "${dim}\$%s${reset}" "$cost_fmt")  "
fi
if [ -n "$lines_added" ] || [ -n "$lines_removed" ]; then
  line_part=""
  [ -n "$lines_added" ]   && line_part="${line_part}$(printf "${green}+%s${reset}" "$lines_added")"
  [ -n "$lines_removed" ] && line_part="${line_part} $(printf "${red}-%s${reset}" "$lines_removed")"
  parts="${parts}${line_part# }  "
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
    s_cwd=$(jq -r '.cwd // empty' "$f" 2>/dev/null)
    s_waiting_for=$(jq -r '.waitingFor // empty' "$f" 2>/dev/null)
    s_updated_at=$(jq -r '.updatedAt // empty' "$f" 2>/dev/null)
    [ "$s_pid" = "$my_parent_pid" ] && continue
    [ "$s_status" = "waiting" ] || [ "$s_status" = "busy" ] || continue
    kill -0 "$s_pid" 2>/dev/null || continue
    [ -z "$s_name" ] && s_name="unnamed"

    s_parts=""
    if [ -n "$s_cwd" ]; then
      s_display=$(echo "$s_cwd" | sed "s|^$HOME|~|")
      s_parts="${s_parts}$(printf "${dim}%s${reset}" "$s_display")  "
      s_branch=$(git -C "$s_cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
      s_toplevel=$(git -C "$s_cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
      s_repo=$([ -n "$s_toplevel" ] && basename "$s_toplevel" || echo "")
      if [ -n "$s_repo" ] && [ -n "$s_branch" ]; then
        s_parts="${s_parts}$(printf "${cyan}%s/%s${reset}" "$s_repo" "$s_branch")  "
      elif [ -n "$s_branch" ]; then
        s_parts="${s_parts}$(printf "${cyan}%s${reset}" "$s_branch")  "
      elif [ -n "$s_repo" ]; then
        s_parts="${s_parts}$(printf "${cyan}%s${reset}" "$s_repo")  "
      fi
      if [ -n "$(git -C "$s_cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        s_parts="${s_parts}$(printf "${yellow}*${reset}")  "
      fi
      s_ab=$(git -C "$s_cwd" --no-optional-locks rev-list --left-right --count "HEAD...@{u}" 2>/dev/null)
      if [ -n "$s_ab" ]; then
        s_ahead=$(echo "$s_ab" | awk '{print $1}')
        s_behind=$(echo "$s_ab" | awk '{print $2}')
        [ "${s_ahead:-0}" -gt 0 ] 2>/dev/null && s_parts="${s_parts}$(printf "${cyan}+%s${reset}" "$s_ahead")  "
        [ "${s_behind:-0}" -gt 0 ] 2>/dev/null && s_parts="${s_parts}$(printf "${cyan}-%s${reset}" "$s_behind")  "
      fi
      s_stash=$(git -C "$s_cwd" --no-optional-locks stash list 2>/dev/null | wc -l | tr -d ' ')
      [ "${s_stash:-0}" -gt 0 ] 2>/dev/null && s_parts="${s_parts}$(printf "${dim}~%s${reset}" "$s_stash")  "
    fi
    if [ -n "$s_waiting_for" ]; then
      s_elapsed_str=""
      if [ -n "$s_updated_at" ]; then
        s_elapsed=$(( now - s_updated_at / 1000 ))
        s_elapsed_str=" ($(format_time_remaining "$s_elapsed"))"
      fi
      s_parts="${s_parts}$(printf "${yellow}Waiting for %s%s${reset}" "$s_waiting_for" "$s_elapsed_str")  "
    elif [ -n "$s_updated_at" ]; then
      s_elapsed=$(( now - s_updated_at / 1000 ))
      s_parts="${s_parts}$(printf "${dim}%s ago${reset}" "$(format_time_remaining "$s_elapsed")")  "
    fi

    if [ "$s_status" = "waiting" ]; then
      s_prefix=$(printf "${yellow}? %s${reset}" "$s_name")
    else
      s_prefix=$(printf "${dim}> %s${reset}" "$s_name")
    fi
    s_line="$s_prefix"
    [ -n "${s_parts%  }" ] && s_line="${s_line}  ${s_parts%  }"
    session_lines="${session_lines}
${s_line}"
  done
fi

# Insights tip (rotates hourly from latest /insights report)
tip_text=""
tip_helper="$(dirname "${BASH_SOURCE[0]}")/insights-tip/extract-tip.sh"
if [ -f "$tip_helper" ]; then
  . "$tip_helper"
  tip_text=$(get_insights_tip "$now")
fi

# Shorten folder/branch when row 1 exceeds the width budget. Shorten the longer
# of the two first (folder=middle segments, branch=tail); if still too long,
# shorten the other too.
budget=$(_width_budget)
row1="${parts%  }"
vis=$(_visible_len "$row1")
if [ "$vis" -gt "$budget" ] 2>/dev/null; then
  overflow=$((vis - budget))
  folder="$display_path"
  branch="$git_branch"
  folder_len=${#folder}
  branch_len=${#branch}
  order=()
  if [ "$folder_len" -ge "$branch_len" ]; then
    [ -n "$folder" ] && order+=("folder")
    [ -n "$branch" ] && order+=("branch")
  else
    [ -n "$branch" ] && order+=("branch")
    [ -n "$folder" ] && order+=("folder")
  fi
  remaining=$overflow
  for kind in "${order[@]}"; do
    [ "$remaining" -le 0 ] && break
    if [ "$kind" = "folder" ]; then
      tgt=$((folder_len - remaining)); [ "$tgt" -lt 0 ] && tgt=0
      new_folder=$(_compress_folder "$folder" "$tgt")
      removed=$((folder_len - ${#new_folder}))
      if [ "$removed" -gt 0 ]; then
        parts="${parts/"$folder"/"$new_folder"}"
        remaining=$((remaining - removed))
      fi
    else
      tgt=$((branch_len - remaining)); [ "$tgt" -lt 0 ] && tgt=0
      new_branch=$(_compress_branch "$branch" "$tgt")
      removed=$((branch_len - ${#new_branch}))
      if [ "$removed" -gt 0 ]; then
        if [ -n "$git_repo" ]; then
          pat="${git_repo}/${branch}"; repl="${git_repo}/${new_branch}"
        else
          pat="$branch"; repl="$new_branch"
        fi
        parts="${parts/"$pat"/"$repl"}"
        remaining=$((remaining - removed))
      fi
    fi
  done
fi

output="${parts%  }"
if [ -n "$session_lines" ]; then
  output="${output}${session_lines}"
fi
if [ -n "$tip_text" ]; then
  output="${output}
$(printf "${dim}%s${reset}" "$tip_text")"
fi
printf "%s" "$output"
