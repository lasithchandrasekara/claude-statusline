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

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

$parts = @()

# Current working directory (shortened)
$cwd = if ($json.workspace.current_dir) { $json.workspace.current_dir } else { $json.cwd }
if ($cwd) {
    $displayPath = ($cwd -replace [regex]::Escape($env:USERPROFILE), '~') -replace '\\', '/'
    $parts += "${dim}${displayPath}${reset}"
}

# Git repo name, branch, and inline status
if ($cwd) {
    $gitBranch = git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>$null
    $gitTopLevel = git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>$null
    $gitRepoName = if ($gitTopLevel) { Split-Path -Leaf $gitTopLevel } else { $null }
    if ($gitRepoName -and $gitBranch) {
        $parts += "${cyan}${gitRepoName}/${gitBranch}${reset}"
    } elseif ($gitBranch) {
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

$output = $parts -join "  "
foreach ($line in $sessionLines) {
    $output += "`n" + $line
}
if ($tipText) {
    $output += "`n${dim}${tipText}${reset}"
}
[Console]::Write($output)
