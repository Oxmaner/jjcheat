$ErrorActionPreference = 'Continue'
$src = Get-Content 'E:\work\mcp.ps1' -Raw -Encoding UTF8
Invoke-Expression $src

$outDir = 'E:\work\diag'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$trace  = Join-Path $outDir ("run-$stamp.hud.log")
$slog   = Join-Path $outDir ("run-$stamp.syslog.log")
$shotDir= Join-Path $outDir ("run-$stamp.shots")
New-Item -ItemType Directory -Path $shotDir -Force | Out-Null

Connect-Mcp
Write-Output ('session=' + $script:MCP_SID)
Write-Output ('trace=' + $trace)
Write-Output ('syslog=' + $slog)
Write-Output ('shots=' + $shotDir)

"# run start $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $trace -Encoding UTF8
"# syslog start $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $slog -Encoding UTF8

$deadline = (Get-Date).AddMinutes(12)
$lastHud = ''; $lastFg = ''; $n = 0; $shotN = 0
while ((Get-Date) -lt $deadline) {
    $n++
    try {
        if ($n -eq 1 -or $n % 10 -eq 1) {
            try {
                $fgo = (Get-McpText -Result (Invoke-McpTool -Tool 'get_frontmost_app' -Params @{} -TimeoutSec 30)) | ConvertFrom-Json
                $bid = [string]$fgo.bundleId
                if ($bid -ne $lastFg) { $lastFg = $bid; ('{0} FG {1}' -f (Get-Date -Format 'HH:mm:ss'), $bid) | Out-File -FilePath $trace -Append -Encoding UTF8 }
            } catch {}
        }

        if ($n % 9 -eq 0) {
            try {
                $so = (Get-McpText -Result (Invoke-McpTool -Tool 'get_syslog' -Params @{ last_seconds = 7; max_lines = 5000; process = 'TKLobby_chess_tuanjie' } -TimeoutSec 90)) | ConvertFrom-Json
                foreach ($e in $so.entries) {
                    $m = [string]$e.message
                    if ($m -match 'JJCheat') { ('{0} | {1}' -f $e.date.Substring(11,8), $m) | Out-File -FilePath $slog -Append -Encoding UTF8 }
                }
            } catch {}
            continue
        }

        $o = (Get-McpText -Result (Invoke-McpTool -Tool 'ocr_screen' -Params @{} -TimeoutSec 90)) | ConvertFrom-Json
        if (-not $o.texts) { Start-Sleep -Milliseconds 700; continue }
        $hud = @()
        foreach ($t in $o.texts) { if ($t.rect.y -lt 140) { $hud += [string]$t.text } }
        $line = ($hud -join ' | ')
        if ($line -ne $lastHud) {
            $lastHud = $line
            $shotN++
            ('{0} HUD {1}' -f (Get-Date -Format 'HH:mm:ss'), $line) | Out-File -FilePath $trace -Append -Encoding UTF8
            try {
                $sr = Invoke-McpTool -Tool 'screenshot' -Params @{} -TimeoutSec 60
                foreach ($c in $sr.content) {
                    if ($c.type -eq 'image' -and $shotN -le 60) {
                        [System.IO.File]::WriteAllBytes((Join-Path $shotDir ('h-{0:d3}.jpg' -f $shotN)), [Convert]::FromBase64String($c.data))
                        break
                    }
                }
            } catch {}
        }
    } catch {
        ('{0} ERR {1}' -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message) | Out-File -FilePath $trace -Append -Encoding UTF8
        try { Connect-Mcp } catch {}
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Milliseconds 700
}
"# run end $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') samples=$n" | Out-File -FilePath $trace -Append -Encoding UTF8
Write-Output "DONE trace=$trace samples=$n"

