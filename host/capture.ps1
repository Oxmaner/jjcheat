$ErrorActionPreference = 'Continue'
$src = Get-Content 'E:\work\mcp.ps1' -Raw -Encoding UTF8
Invoke-Expression $src

$outDir = 'E:\work\diag'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$outFile = Join-Path $outDir ('jjcheat-syslog-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
"# capture start $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $outFile -Encoding UTF8

Connect-Mcp
Write-Output ('session=' + $script:MCP_SID)
Write-Output ('out=' + $outFile)

$deadline = (Get-Date).AddMinutes(15)
$total = 0
$hits  = 0
while ((Get-Date) -lt $deadline) {
    try {
        $res = Invoke-McpTool -Tool 'get_syslog' -Params @{ last_seconds = 55; max_lines = 5000; process = 'TKLobby_chess_tuanjie' } -TimeoutSec 150
        $txt = Get-McpText -Result $res
        $obj = $null
        try { $obj = $txt | ConvertFrom-Json } catch { $obj = $null }
        if ($obj -and $obj.entries) {
            foreach ($e in $obj.entries) {
                $total++
                $m = [string]$e.message
                if ($m -match 'JJCheat') {
                    $hits++
                    ('{0} | {1} | {2}' -f $e.date, $e.pid, $m) | Out-File -FilePath $outFile -Append -Encoding UTF8
                }
            }
        }
        Write-Output ('{0} entries={1} jjcheat={2} total={3} hits={4}' -f (Get-Date -Format 'HH:mm:ss'), $obj.entries.Count, $hits, $total, $hits)
    } catch {
        Write-Output ('{0} ERR {1}' -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message)
        try { Connect-Mcp } catch { }
        Start-Sleep -Seconds 3
    }
}
"# capture end $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') entries=$total hits=$hits" | Out-File -FilePath $outFile -Append -Encoding UTF8
Write-Output "DONE out=$outFile entries=$total hits=$hits"
