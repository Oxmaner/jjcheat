$ErrorActionPreference = 'Continue'
$src = Get-Content 'E:\work\mcp.ps1' -Raw -Encoding UTF8
Invoke-Expression $src

$outDir = 'E:\work\diag'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$trace = Join-Path $outDir ('hud-trace-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$shotDir = Join-Path $outDir ('shots-' + (Get-Date -Format 'HHmmss'))
New-Item -ItemType Directory -Path $shotDir -Force | Out-Null

Connect-Mcp
Write-Output ('session=' + $script:MCP_SID)
Write-Output ('trace=' + $trace)
Write-Output ('shots=' + $shotDir)
"# hud trace start $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $trace -Encoding UTF8

$deadline = (Get-Date).AddMinutes(25)
$lastHud = ''
$lastFg  = ''
$n = 0
$shotN = 0
while ((Get-Date) -lt $deadline) {
    $n++
    try {
        # 1) which app is frontmost (cheap, every 5th sample)
        if ($n % 5 -eq 1) {
            try {
                $fr = Invoke-McpTool -Tool 'get_frontmost_app' -Params @{} -TimeoutSec 30
                $fg = Get-McpText -Result $fr
                $fgo = $null
                try { $fgo = $fg | ConvertFrom-Json } catch {}
                $bid = if ($fgo) { [string]$fgo.bundleId } else { '?' }
                if ($bid -ne $lastFg) {
                    $lastFg = $bid
                    ('{0} FG {1}' -f (Get-Date -Format 'HH:mm:ss'), $bid) | Out-File -FilePath $trace -Append -Encoding UTF8
                }
            } catch {}
        }

        # 2) OCR whole screen, keep only the top strip (HUD panel)
        $res = Invoke-McpTool -Tool 'ocr_screen' -Params @{} -TimeoutSec 90
        $txt = Get-McpText -Result $res
        $o = $null
        try { $o = $txt | ConvertFrom-Json } catch { $o = $null }
        if (-not $o -or -not $o.texts) { Start-Sleep -Milliseconds 800; continue }

        $hud = @()
        foreach ($t in $o.texts) {
            if ($t.rect.y -lt 135) { $hud += ([string]$t.text) }
        }
        $hudLine = ($hud -join ' | ')
        if ($hudLine -ne $lastHud) {
            $lastHud = $hudLine
            $shotN++
            ('{0} HUD {1}' -f (Get-Date -Format 'HH:mm:ss'), $hudLine) | Out-File -FilePath $trace -Append -Encoding UTF8
            # save a screenshot for the changed HUD state
            try {
                $sr = Invoke-McpTool -Tool 'screenshot' -Params @{} -TimeoutSec 60
                foreach ($c in $sr.content) {
                    if ($c.type -eq 'image') {
                        $bytes = [Convert]::FromBase64String($c.data)
                        $p = Join-Path $shotDir ('hud-{0:d3}.jpg' -f $shotN)
                        [System.IO.File]::WriteAllBytes($p, $bytes)
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
    Start-Sleep -Milliseconds 1200
}
"# hud trace end $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') samples=$n" | Out-File -FilePath $trace -Append -Encoding UTF8
Write-Output "DONE trace=$trace samples=$n shots=$shotN"
