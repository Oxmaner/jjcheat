$ErrorActionPreference = 'Stop'
$src = Get-Content 'E:\work\mcp.ps1' -Raw -Encoding UTF8
Invoke-Expression $src
Connect-Mcp

$D = '/var/mobile/Containers/Data/Application/141CCCF6-0FE0-4492-8E22-5EDFAC205EF5/Library/Application Support/JJCheat'
$lf = 'E:\work\diag\engine.r37.lf.js'
$txtNow = [System.IO.File]::ReadAllText('E:\work\jjcheat\dist\engine.js', [System.Text.Encoding]::UTF8).Replace("`r`n","`n")
[System.IO.File]::WriteAllText($lf, $txtNow, (New-Object System.Text.UTF8Encoding($false)))
$hostMd5 = (Get-FileHash $lf -Algorithm MD5).Hash
Write-Output ("HOST md5 = " + $hostMd5 + "  bytes=" + (Get-Item $lf).Length)

$bytes = [System.IO.File]::ReadAllBytes($lf)
$b64 = [Convert]::ToBase64String($bytes)
# base64 是纯 ASCII，1 字符=1 字节，不会像中文那样被 JSON 转义放大
$chunk = 13000
$n = [Math]::Ceiling($b64.Length / $chunk)
Write-Output ("base64 len=" + $b64.Length + "  chunks=" + $n)

for ($i = 0; $i -lt $n; $i++) {
    $start = $i * $chunk
    $len = [Math]::Min($chunk, $b64.Length - $start)
    $part = $b64.Substring($start, $len)
    $name = ('e.b{0:d3}' -f $i)
    $res = Invoke-McpTool -Tool 'write_file' -Params @{ path = "$D/$name"; content = $part } -TimeoutSec 90
    $o = (Get-McpText -Result $res) | ConvertFrom-Json
    if ($o.bytes_written -ne $len) { throw ("chunk $i wrote " + $o.bytes_written + " want " + $len) }
}
Write-Output ("wrote " + $n + " chunks ok")

$cmd = @"
D="$D"
cd "`$D" || exit 1
cat e.b* > e.all.b64
wc -c e.all.b64
base64 -d e.all.b64 > engine.js.new 2>e.err
echo "decode exit=`$?"
cat e.err
wc -c engine.js.new
md5 engine.js.new
"@
Show-McpTool -Tool 'run_command' -Params @{ command = $cmd; timeout = 40 }
