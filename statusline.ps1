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

# Git branch
$cwd = if ($json.workspace.current_dir) { $json.workspace.current_dir } else { $json.cwd }
if ($cwd) {
    $gitBranch = git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>$null
    if ($gitBranch) {
        $parts += "${cyan}${gitBranch}${reset}"
    }
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

[Console]::Write($parts -join "  ")
