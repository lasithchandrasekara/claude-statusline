$json = [Console]::In.ReadToEnd() | ConvertFrom-Json

$ESC   = [char]27
$reset  = "$ESC[0m"
$cyan   = "$ESC[36m"
$yellow = "$ESC[33m"
$red    = "$ESC[31m"
$green  = "$ESC[32m"
$white  = "$ESC[37m"
$dim    = "$ESC[2m"

function Format-TimeRemaining([long]$seconds) {
    if ($seconds -le 0) { return "now" }
    $d = [int]($seconds / 86400)
    $h = [int](($seconds % 86400) / 3600)
    $m = [int](($seconds % 3600) / 60)
    if ($d -gt 0) { return "${d}d${h}h" }
    if ($h -gt 0) { return "${h}h${m}m" }
    return "${m}m"
}

function Get-VisibleLength([string]$s) {
    return ([regex]::Replace($s, "$([char]27)\[[0-9;]*m", "")).Length
}

# Width budget for row 1. Terminal width can't be detected in the statusline
# spawn (no console, no env var from Claude Code), so this is a fixed value:
# STATUSLINE_MAX_WIDTH env var if set, else a 200-column default.
function Get-WidthBudget {
    $envW = 0
    if ($env:STATUSLINE_MAX_WIDTH -and [int]::TryParse($env:STATUSLINE_MAX_WIDTH, [ref]$envW) -and $envW -gt 0) {
        return $envW
    }
    return 200
}

# Drop whole middle directory segments (keep root + leaf) until the path fits $target.
function Compress-FolderPath([string]$path, [int]$target) {
    $segs = $path -split '/'
    if ($segs.Count -le 2) { return $path }
    $last = $segs[$segs.Count - 1]
    for ($keep = $segs.Count - 1; $keep -ge 1; $keep--) {
        if ($keep -ge ($segs.Count - 1)) {
            $candidate = $path
        } else {
            $candidate = (($segs[0..($keep - 1)]) -join '/') + '/.../' + $last
        }
        if ($candidate.Length -le $target) { return $candidate }
    }
    return $segs[0] + '/.../' + $last
}

# Trim the tail of a branch (keep the front), append "...", with a 20-char floor
# so a "type/ticket" prefix like "feature/lsc.716962" survives.
function Compress-Branch([string]$branch, [int]$target) {
    if ($branch.Length -le $target) { return $branch }
    $keep = $target - 3
    if ($keep -lt 20) { $keep = 20 }
    if ($keep -ge $branch.Length) { return $branch }
    return $branch.Substring(0, $keep) + '...'
}

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

$parts = @()
$folderIdx = -1
$branchIdx = -1

# Current working directory (shortened)
$cwd = if ($json.workspace.current_dir) { $json.workspace.current_dir } else { $json.cwd }
if ($cwd) {
    $displayPath = ($cwd -replace [regex]::Escape($env:USERPROFILE), '~') -replace '\\', '/'
    $folderIdx = $parts.Count
    $parts += "${dim}${displayPath}${reset}"
}

# Git repo name, branch, and inline status
if ($cwd) {
    $gitBranch = git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>$null
    $gitTopLevel = git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>$null
    $gitRepoName = if ($gitTopLevel) { Split-Path -Leaf $gitTopLevel } else { $null }
    if ($gitRepoName -and $gitBranch) {
        $branchIdx = $parts.Count
        $parts += "${cyan}${gitRepoName}/${gitBranch}${reset}"
    } elseif ($gitBranch) {
        $branchIdx = $parts.Count
        $parts += "${cyan}${gitBranch}${reset}"
    } elseif ($gitRepoName) {
        $parts += "${cyan}${gitRepoName}${reset}"
    }

    # Git status inline after branch
    $dirty = git -C "$cwd" --no-optional-locks status --porcelain 2>$null
    if ($dirty) { $parts += "${yellow}*${reset}" }

    $revList = git -C "$cwd" --no-optional-locks rev-list --left-right --count "HEAD...@{u}" 2>$null
    if ($revList) {
        $counts = ([string]$revList).Trim() -split '\s+'
        if ($counts.Count -ge 2) {
            $ahead  = [int]$counts[0]
            $behind = [int]$counts[1]
            if ($ahead  -gt 0) { $parts += "${cyan}+${ahead}${reset}" }
            if ($behind -gt 0) { $parts += "${cyan}-${behind}${reset}" }
        }
    }

    $stashCount = @(git -C "$cwd" --no-optional-locks stash list 2>$null).Count
    if ($stashCount -gt 0) { $parts += "${dim}~${stashCount}${reset}" }
}

# Model + effort level
$model = if ($json.model.display_name) { $json.model.display_name } else { "Unknown model" }
$effort = $json.effort.level
$modelStr = "${white}${model}${reset}"
if ($effort -and $effort -ne "normal") { $modelStr += "  ${dim}effort:${effort}${reset}" }
$parts += $modelStr

# Context % with token count
$usedPct = $json.context_window.used_percentage
if ($null -ne $usedPct) {
    $usedInt = [int]$usedPct
    $color = if ($usedInt -ge 80) { $red } elseif ($usedInt -ge 60) { $yellow } else { $green }
    $usedTokens = $json.context_window.total_input_tokens
    $ctxSize = $json.context_window.context_window_size
    $tokenStr = if ($usedTokens -and $ctxSize) {
        $usedK = [math]::Round($usedTokens / 1000)
        $sizeK = [math]::Round($ctxSize / 1000)
        "${dim}(${usedK}k/${sizeK}k)${reset}"
    } else { "" }
    $parts += "ctx:${color}$([int]$usedPct)%${reset}${tokenStr}"
}

# Session cost and lines changed
$totalCost = $json.cost.total_cost_usd
if ($null -ne $totalCost) {
    $parts += "${dim}`$$([math]::Round($totalCost, 2).ToString('0.00'))${reset}"
}
$linesAdded   = $json.cost.total_lines_added
$linesRemoved = $json.cost.total_lines_removed
if ($linesAdded -or $linesRemoved) {
    $linePart = ""
    if ($linesAdded)   { $linePart += "${green}+${linesAdded}${reset}" }
    if ($linesRemoved) { $linePart += " ${red}-${linesRemoved}${reset}" }
    $parts += $linePart.Trim()
}

# 5-hour session usage
$fiveHour = $json.rate_limits.five_hour.used_percentage
if ($null -ne $fiveHour) {
    $fiveInt = [int]$fiveHour
    $color = if ($fiveInt -ge 80) { $red } elseif ($fiveInt -ge 60) { $yellow } else { $green }
    $part = "5h:${color}$([int]$fiveHour)%${reset}"
    $fiveResetsAt = $json.rate_limits.five_hour.resets_at
    if ($null -ne $fiveResetsAt) {
        $remaining = [long]$fiveResetsAt - $now
        $part += "${dim}($(Format-TimeRemaining $remaining))${reset}"
    }
    $parts += $part
}

# 7-day weekly usage
$sevenDay = $json.rate_limits.seven_day.used_percentage
if ($null -ne $sevenDay) {
    $sevenInt = [int]$sevenDay
    $color = if ($sevenInt -ge 80) { $red } elseif ($sevenInt -ge 60) { $yellow } else { $green }
    $part = "7d:${color}$([int]$sevenDay)%${reset}"
    $sevenResetsAt = $json.rate_limits.seven_day.resets_at
    if ($null -ne $sevenResetsAt) {
        $remaining = [long]$sevenResetsAt - $now
        $part += "${dim}($(Format-TimeRemaining $remaining))${reset}"
    }
    $parts += $part
}

# Other Claude sessions (waiting or busy, excluding this one) — one per line
$myParentPid = try { (Get-Process -Id $PID -ErrorAction Stop).Parent.Id } catch { $null }
$sessionLines = @()
$sessionDir = Join-Path $env:USERPROFILE ".claude\sessions"
if (Test-Path $sessionDir) {
    foreach ($file in Get-ChildItem "$sessionDir\*.json" -ErrorAction SilentlyContinue) {
        try {
            $session = Get-Content $file.FullName -Raw | ConvertFrom-Json
            if ($session.pid -eq $myParentPid) { continue }
            if ($session.status -notin @('waiting', 'busy')) { continue }
            if (-not (Get-Process -Id $session.pid -ErrorAction SilentlyContinue)) { continue }
            $sessionName = if ($session.name) { $session.name.Trim('"') } else { "unnamed" }

            $sParts = @()
            $sCwd = $session.cwd
            if ($sCwd) {
                $sDisplayPath = ($sCwd -replace [regex]::Escape($env:USERPROFILE), '~') -replace '\\', '/'
                $sParts += "${dim}${sDisplayPath}${reset}"
                $sBranch   = git -C "$sCwd" --no-optional-locks symbolic-ref --short HEAD 2>$null
                $sTopLevel = git -C "$sCwd" --no-optional-locks rev-parse --show-toplevel 2>$null
                $sRepo     = if ($sTopLevel) { Split-Path -Leaf $sTopLevel } else { $null }
                if ($sRepo -and $sBranch) { $sParts += "${cyan}${sRepo}/${sBranch}${reset}" }
                elseif ($sBranch)         { $sParts += "${cyan}${sBranch}${reset}" }
                elseif ($sRepo)           { $sParts += "${cyan}${sRepo}${reset}" }
                $sDirty = git -C "$sCwd" --no-optional-locks status --porcelain 2>$null
                if ($sDirty) { $sParts += "${yellow}*${reset}" }
                $sRevList = git -C "$sCwd" --no-optional-locks rev-list --left-right --count "HEAD...@{u}" 2>$null
                if ($sRevList) {
                    $sCounts = ([string]$sRevList).Trim() -split '\s+'
                    if ($sCounts.Count -ge 2) {
                        if ([int]$sCounts[0] -gt 0) { $sParts += "${cyan}+$($sCounts[0])${reset}" }
                        if ([int]$sCounts[1] -gt 0) { $sParts += "${cyan}-$($sCounts[1])${reset}" }
                    }
                }
                $sStash = @(git -C "$sCwd" --no-optional-locks stash list 2>$null).Count
                if ($sStash -gt 0) { $sParts += "${dim}~${sStash}${reset}" }
            }
            if ($session.waitingFor) {
                $sElapsedStr = ""
                if ($session.updatedAt) {
                    $sElapsed = $now - [long]($session.updatedAt / 1000)
                    $sElapsedStr = " ($(Format-TimeRemaining $sElapsed))"
                }
                $sParts += "${yellow}Waiting for $($session.waitingFor)${sElapsedStr}${reset}"
            } elseif ($session.updatedAt) {
                $sElapsed = $now - [long]($session.updatedAt / 1000)
                $sParts += "${dim}$(Format-TimeRemaining $sElapsed) ago${reset}"
            }

            $sDetail = if ($sParts.Count -gt 0) { "  " + ($sParts -join "  ") } else { "" }
            if ($session.status -eq 'waiting') {
                $sessionLines += "${yellow}? ${sessionName}${reset}${sDetail}"
            } else {
                $sessionLines += "${dim}> ${sessionName}${reset}${sDetail}"
            }
        } catch {}
    }
}

# Insights tip (rotates hourly from latest /insights report)
$tipText = $null
$tipHelper = Join-Path $PSScriptRoot "insights-tip\extract-tip.ps1"
if (Test-Path $tipHelper) {
    . $tipHelper
    try { $tipText = Get-InsightsTip -Now $now } catch { $tipText = $null }
}

# Shorten folder/branch when row 1 exceeds the terminal width budget.
# Shorten the longer of the two first (folder=middle segments, branch=tail);
# if still too long, shorten the other too.
$budget = Get-WidthBudget
if ((Get-VisibleLength ($parts -join "  ")) -gt $budget) {
    $overflow = (Get-VisibleLength ($parts -join "  ")) - $budget
    $folder = if ($folderIdx -ge 0) { $displayPath } else { $null }
    $branch = if ($branchIdx -ge 0) { $gitBranch } else { $null }
    $folderLen = 0
    if ($folder) { $folderLen = $folder.Length }
    $branchLen = 0
    if ($branch) { $branchLen = $branch.Length }

    $order = @()
    if ($folderLen -ge $branchLen) {
        if ($folder) { $order += 'folder' }
        if ($branch) { $order += 'branch' }
    } else {
        if ($branch) { $order += 'branch' }
        if ($folder) { $order += 'folder' }
    }

    $remaining = $overflow
    foreach ($kind in $order) {
        if ($remaining -le 0) { break }
        if ($kind -eq 'folder') {
            $target = [Math]::Max(0, $folder.Length - $remaining)
            $newFolder = Compress-FolderPath $folder $target
            $removed = $folder.Length - $newFolder.Length
            if ($removed -gt 0) {
                $parts[$folderIdx] = "${dim}${newFolder}${reset}"
                $remaining -= $removed
            }
        } else {
            $target = [Math]::Max(0, $branch.Length - $remaining)
            $newBranch = Compress-Branch $branch $target
            $removed = $branch.Length - $newBranch.Length
            if ($removed -gt 0) {
                if ($gitRepoName) {
                    $parts[$branchIdx] = "${cyan}${gitRepoName}/${newBranch}${reset}"
                } else {
                    $parts[$branchIdx] = "${cyan}${newBranch}${reset}"
                }
                $remaining -= $removed
            }
        }
    }
}

$output = $parts -join "  "
foreach ($line in $sessionLines) {
    $output += "`n" + $line
}
if ($tipText) {
    $output += "`n${dim}${tipText}${reset}"
}
[Console]::Write($output)
