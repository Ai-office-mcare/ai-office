# AI 오피스 - 로컬 웹서버
# 설치 없이 Windows 기본 PowerShell 만으로 http://localhost:8787 을 띄웁니다.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$port = 8787

# 이미 떠 있으면 브라우저만 연다
$busy = $null
try { $busy = (New-Object Net.Sockets.TcpClient).ConnectAsync('127.0.0.1', $port).Wait(300) } catch { $busy = $false }
if ($busy) {
    Write-Host "이미 실행 중입니다. 브라우저를 엽니다..." -ForegroundColor Yellow
    Start-Process "http://localhost:$port/"
    exit 0
}

$mime = @{
    '.html'='text/html; charset=utf-8'; '.htm'='text/html; charset=utf-8'
    '.js'='text/javascript; charset=utf-8'; '.css'='text/css; charset=utf-8'
    '.json'='application/json; charset=utf-8'; '.md'='text/markdown; charset=utf-8'
    '.svg'='image/svg+xml'; '.png'='image/png'; '.jpg'='image/jpeg'; '.jpeg'='image/jpeg'
    '.gif'='image/gif'; '.ico'='image/x-icon'; '.woff2'='font/woff2'; '.txt'='text/plain; charset=utf-8'
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try {
    $listener.Start()
} catch {
    Write-Host ""
    Write-Host "포트 $port 를 열지 못했습니다." -ForegroundColor Red
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "아무 키나 누르면 닫힙니다."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

Write-Host ""
Write-Host "  AI 오피스 실행 중" -ForegroundColor Cyan
Write-Host "  http://localhost:$port/" -ForegroundColor White
Write-Host ""
Write-Host "  종료하려면 이 창에서 Ctrl+C 를 누르거나 창을 닫으세요." -ForegroundColor DarkGray
Write-Host ""

Start-Process "http://localhost:$port/"

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        try {
            $rel = [Uri]::UnescapeDataString($req.Url.AbsolutePath).TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($rel)) { $rel = 'index.html' }
            $rel = $rel -replace '/', '\'

            $full = [IO.Path]::GetFullPath((Join-Path $root $rel))

            # 디렉터리 탈출 차단
            if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                $res.StatusCode = 403
                $b = [Text.Encoding]::UTF8.GetBytes('403 Forbidden')
                $res.OutputStream.Write($b, 0, $b.Length)
            }
            elseif (Test-Path -LiteralPath $full -PathType Leaf) {
                $ext = [IO.Path]::GetExtension($full).ToLower()
                $res.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
                $res.Headers.Add('Cache-Control', 'no-store')
                $bytes = [IO.File]::ReadAllBytes($full)
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                Write-Host ("  200  " + $req.Url.AbsolutePath) -ForegroundColor DarkGray
            }
            else {
                $res.StatusCode = 404
                $b = [Text.Encoding]::UTF8.GetBytes('404 Not Found')
                $res.OutputStream.Write($b, 0, $b.Length)
                Write-Host ("  404  " + $req.Url.AbsolutePath) -ForegroundColor DarkYellow
            }
        } catch {
            try { $res.StatusCode = 500 } catch {}
        } finally {
            try { $res.OutputStream.Close() } catch {}
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
