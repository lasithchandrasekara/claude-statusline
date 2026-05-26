function Get-InsightsTip {
    param(
        [Parameter(Mandatory)][long]$Now
    )

    $tipFile = Join-Path $env:USERPROFILE ".claude\statusline-tip.json"
    $cached = $null
    if (Test-Path $tipFile) {
        try { $cached = Get-Content $tipFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $cached = $null }
    }
    if ($cached -and $cached.expires_at -gt $Now -and $cached.tips -and $cached.current_tip_index) {
        $idx = [int]$cached.current_tip_index
        $current = $cached.tips | Where-Object { [int]$_.index -eq $idx } | Select-Object -First 1
        if ($current) {
            return "tip #${idx}: $($current.text)  (/tip ${idx} for details)"
        }
    }

    $usageDir = Join-Path $env:USERPROFILE ".claude\usage-data"
    if (-not (Test-Path $usageDir)) { return $null }

    $latest = Get-ChildItem "$usageDir\report-*.html" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return $null }

    try {
        $html = Get-Content $latest.FullName -Raw -ErrorAction Stop
    } catch {
        return $null
    }

    $rawTips = @()

    # CLAUDE.md additions: title from cmd-code, details from cmd-why
    $mdRegex = '<div class="claude-md-item">.*?<code class="cmd-code">## ([^\n<]+).*?<div class="cmd-why">([^<]+)</div>'
    foreach ($m in [regex]::Matches($html, $mdRegex, 'Singleline')) {
        $title = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value).Trim()
        $why   = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value).Trim()
        $rawTips += @{ text = "claude.md: $title"; details = $why }
    }

    # Pattern cards: title plus combined summary + detail
    $patRegex = '<div class="pattern-card">.*?<div class="pattern-title">([^<]+)</div>.*?<div class="pattern-summary">([^<]+)</div>.*?<div class="pattern-detail">([^<]+)</div>'
    foreach ($m in [regex]::Matches($html, $patRegex, 'Singleline')) {
        $title    = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value).Trim()
        $summary  = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value).Trim()
        $detail   = [System.Net.WebUtility]::HtmlDecode($m.Groups[3].Value).Trim()
        $combined = "$summary $detail"
        if ($combined.Length -gt 400) { $combined = $combined.Substring(0, 397) + '...' }
        $rawTips += @{ text = "pattern: $title"; details = $combined }
    }

    if ($rawTips.Count -eq 0) { return $null }

    $indexed = @()
    for ($i = 0; $i -lt $rawTips.Count; $i++) {
        $indexed += [ordered]@{
            index   = ($i + 1)
            text    = $rawTips[$i].text
            details = $rawTips[$i].details
        }
    }

    $epochHour  = [long]([Math]::Floor($Now / 3600))
    $currentIdx = ($epochHour % $indexed.Count) + 1

    $cacheObj = [ordered]@{
        current_tip_index = $currentIdx
        expires_at        = $Now + 3600
        source_report     = $latest.Name
        generated_at      = $Now
        tips              = $indexed
    }
    try {
        $cacheObj | ConvertTo-Json -Depth 10 | Set-Content $tipFile -Encoding UTF8 -ErrorAction Stop
    } catch {}

    Install-TipCommand

    $currentText = $indexed[$currentIdx - 1].text
    return "tip #${currentIdx}: ${currentText}  (/tip ${currentIdx} for details)"
}

function Install-TipCommand {
    $cmdDir       = Join-Path $env:USERPROFILE ".claude\commands"
    $cmdFile      = Join-Path $cmdDir "tip.md"
    $optOutMarker = Join-Path $cmdDir ".tip-uninstalled"

    if (Test-Path $optOutMarker) { return }
    if (Test-Path $cmdFile) { return }
    if (-not (Test-Path $cmdDir)) {
        try { New-Item -ItemType Directory -Path $cmdDir -Force -ErrorAction Stop | Out-Null } catch { return }
    }

    $content = @'
---
description: Show full details of the current statusline tip
argument-hint: [tip number, e.g. 5]
---

Read the file at `$HOME/.claude/statusline-tip.json` (on Windows: `$env:USERPROFILE\.claude\statusline-tip.json`). The user invoked `/tip` with argument: `$ARGUMENTS`

- If the argument is empty, find the tip in the `tips` array whose `index` equals the top-level `current_tip_index` field.
- If the argument is a number, find the tip in the `tips` array whose `index` equals that number.
- If no matching tip exists, respond with exactly: `No such tip — valid range is 1 to <N>` where `<N>` is the highest `index` in the `tips` array.

Print only the `details` field of the matched tip (or the error message above) as a plain string. Do not add headers, code fences, surrounding commentary, or other formatting.
'@
    try {
        Set-Content -Path $cmdFile -Value $content -Encoding UTF8 -ErrorAction Stop
    } catch {}
}
