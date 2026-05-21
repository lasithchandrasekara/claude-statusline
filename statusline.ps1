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
$gitLine2Parts = @()

# Current working directory (shortened)
$cwd = if ($json.workspace.current_dir) { $json.workspace.current_dir } else { $json.cwd }
if ($cwd) {
    $displayPath = ($cwd -replace [regex]::Escape($env:USERPROFILE), '~') -replace '\\', '/'
    $parts += "${dim}${displayPath}${reset}"
}

# Git repo name and branch
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

    # Git status second line
    $dirty = git -C "$cwd" --no-optional-locks status --porcelain 2>$null
    if ($dirty) { $gitLine2Parts += "${yellow}*${reset}" }

    $revList = git -C "$cwd" --no-optional-locks rev-list --left-right --count "HEAD...@{u}" 2>$null
    if ($revList) {
        $counts = ([string]$revList).Trim() -split '\s+'
        if ($counts.Count -ge 2) {
            $ahead  = [int]$counts[0]
            $behind = [int]$counts[1]
            if ($ahead  -gt 0) { $gitLine2Parts += "${cyan}+${ahead}${reset}" }
            if ($behind -gt 0) { $gitLine2Parts += "${cyan}-${behind}${reset}" }
        }
    }

    $stashCount = @(git -C "$cwd" --no-optional-locks stash list 2>$null).Count
    if ($stashCount -gt 0) { $gitLine2Parts += "${dim}~${stashCount}${reset}" }
}

# Model
$model = if ($json.model.display_name) { $json.model.display_name } else { "Unknown model" }
$parts += "${white}${model}${reset}"

# Context %
$usedPct = $json.context_window.used_percentage
if ($null -ne $usedPct) {
    $usedInt = [int]$usedPct
    $color = if ($usedInt -ge 80) { $red } elseif ($usedInt -ge 60) { $yellow } else { $green }
    $parts += "ctx:${color}$([int]$usedPct)%${reset}"
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

# Other Claude sessions (waiting or busy, excluding this one)
$myParentPid = try { (Get-Process -Id $PID -ErrorAction Stop).Parent.Id } catch { $null }
$otherSessionParts = @()
$sessionDir = Join-Path $env:USERPROFILE ".claude\sessions"
if (Test-Path $sessionDir) {
    foreach ($file in Get-ChildItem "$sessionDir\*.json" -ErrorAction SilentlyContinue) {
        try {
            $session = Get-Content $file.FullName -Raw | ConvertFrom-Json
            if ($session.pid -eq $myParentPid) { continue }
            if ($session.status -notin @('waiting', 'busy')) { continue }
            if (-not (Get-Process -Id $session.pid -ErrorAction SilentlyContinue)) { continue }
            $sessionName = if ($session.name) { $session.name.Trim('"') } else { "unnamed" }
            if ($session.status -eq 'waiting') {
                $otherSessionParts += "${yellow}? ${sessionName}${reset}"
            } else {
                $otherSessionParts += "${dim}> ${sessionName}${reset}"
            }
        } catch {}
    }
}

$output = $parts -join "  "
$line2 = $gitLine2Parts -join "  "
if ($otherSessionParts.Count -gt 0) {
    $sep = if ($line2) { "  ${dim}|${reset}  " } else { "" }
    $line2 += $sep + ($otherSessionParts -join "  ")
}
if ($line2) {
    $output += "`n" + $line2
}
[Console]::Write($output)
