$ErrorActionPreference = 'Stop'
$script:MCP_EP  = 'http://192.168.50.210:8090/mcp'
$script:MCP_SID = ''
$script:MCP_ID  = 100

function Connect-Mcp {
    $body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"dsh","version":"1.0"}}}'
    $r = Invoke-WebRequest -Uri $script:MCP_EP -Method Post -Body $body -ContentType 'application/json' -Headers @{'Accept'='application/json, text/event-stream'} -TimeoutSec 20 -UseBasicParsing
    $script:MCP_SID = $r.Headers['Mcp-Session-Id']
    $null = Invoke-WebRequest -Uri $script:MCP_EP -Method Post -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}' -ContentType 'application/json' -Headers @{'Accept'='application/json, text/event-stream';'Mcp-Session-Id'=$script:MCP_SID} -TimeoutSec 15 -UseBasicParsing
    if (-not $script:MCP_SID) { throw 'no session id' }
}

function Invoke-McpTool {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [hashtable]$Params = @{},
        [int]$TimeoutSec = 180
    )
    $script:MCP_ID++
    $payload = @{ jsonrpc = '2.0'; id = $script:MCP_ID; method = 'tools/call'; params = @{ name = $Tool; arguments = $Params } } | ConvertTo-Json -Depth 20 -Compress
    $hdr = @{'Accept'='application/json, text/event-stream';'Mcp-Session-Id'=$script:MCP_SID;'MCP-Protocol-Version'='2025-11-25'}
    $r = Invoke-WebRequest -Uri $script:MCP_EP -Method Post -Body $payload -ContentType 'application/json' -Headers $hdr -TimeoutSec $TimeoutSec -UseBasicParsing
    # MCP returns UTF-8 JSON; PS 5.1 decodes header-less JSON as Latin-1 -> mojibake.
    # Always decode the raw bytes as UTF-8.
    $raw = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    $obj = $null
    foreach ($line in ($raw -split "`n")) {
        $t = $line.Trim()
        if (-not $t.StartsWith('{')) { continue }
        try { $o = $t | ConvertFrom-Json } catch { continue }
        if ($o.id -eq $script:MCP_ID) { $obj = $o; break }
    }
    if (-not $obj) { throw ('no matching response: ' + $r.Content.Substring(0,[Math]::Min(400,$r.Content.Length))) }
    if ($obj.error) { throw ('MCP error: ' + ($obj.error | ConvertTo-Json -Depth 8 -Compress)) }
    return $obj.result
}

function Get-McpText {
    param([Parameter(Mandatory)]$Result)
    $items = @()
    foreach ($c in $Result.content) {
        if ($c.type -eq 'text') { $items += $c.text } else { $items += ('[' + $c.type + ']') }
    }
    return ($items -join "`n")
}

function Show-McpTool {
    param([Parameter(Mandatory)][string]$Tool, [hashtable]$Params = @{})
    $res = Invoke-McpTool -Tool $Tool -Params $Params
    Write-Output ('===== ' + $Tool + ' =====')
    $txt = Get-McpText -Result $res
    if ($txt.Length -gt 14000) { $txt = $txt.Substring(0,14000) + '...[truncated]' }
    Write-Output $txt
    if ($res.isError) { Write-Output ('[isError=' + $res.isError + ']') }
}

function Get-McpArgs {
    param([string]$Json = '{}')
    if ([string]::IsNullOrWhiteSpace($Json)) { return @{} }
    $o = $Json | ConvertFrom-Json
    $h = @{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}
