#Requires -Version 5.1
<#
.SYNOPSIS
  On-demand mihomo proxy manager for Windows PowerShell / CMD (kept stopped by default).

.EXAMPLE
  $env:MIHOMO_DIR="C:\tools\mihomo"; .\scripts\mihomo_ctl.ps1 status
  .\scripts\mihomo_ctl.ps1 run git clone https://github.com/org/repo.git
#>
$ErrorActionPreference = "Stop"

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$MihomoDir  = if ($env:MIHOMO_DIR) { $env:MIHOMO_DIR } else { Join-Path $ScriptDir "mihomo" }
$Bin        = if ($env:MIHOMO_BIN) { $env:MIHOMO_BIN } else { Join-Path $MihomoDir "mihomo.exe" }
if (-not (Test-Path $Bin) -and (Test-Path (Join-Path $MihomoDir "mihomo"))) {
    $Bin = Join-Path $MihomoDir "mihomo"
}
$Cfg        = if ($env:MIHOMO_CONFIG) { $env:MIHOMO_CONFIG } else { Join-Path $MihomoDir "config.yaml" }
$PidFile    = Join-Path $MihomoDir "mihomo.pid"
$LogOut     = Join-Path $MihomoDir "mihomo.log"
$LogErr     = Join-Path $MihomoDir "mihomo.err.log"
$ProxyAddr  = if ($env:MIHOMO_PROXY_ADDR) { $env:MIHOMO_PROXY_ADDR } else { "http://127.0.0.1:7890" }

$Uri = [System.Uri]$ProxyAddr
$ProxyHost = $Uri.Host
$ProxyPort = if ($Uri.Port -gt 0) { $Uri.Port } else { 7890 }

function Test-TcpPort([string]$TargetHost, [int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(500, $false) -and $client.Connected) {
            $client.EndConnect($iar)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-RunningPid {
    if (Test-Path $PidFile) {
        $raw = (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        $parsedPid = 0
        if ([int]::TryParse([string]$raw, [ref]$parsedPid)) {
            $proc = Get-Process -Id $parsedPid -ErrorAction SilentlyContinue
            if ($proc) { return $parsedPid }
        }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
    return 0
}

function Start-Mihomo {
    $runningPid = Get-RunningPid
    if ($runningPid -gt 0) {
        Write-Host "mihomo already running (pid=$runningPid)"
        return
    }
    if (-not (Test-Path $Bin)) {
        Write-Error "mihomo binary not found: $Bin"
        exit 1
    }
    if (-not (Test-Path $Cfg)) {
        Write-Error "mihomo config not found: $Cfg"
        exit 1
    }
    if (-not (Test-Path (Join-Path $MihomoDir "Country.mmdb"))) {
        Write-Warning "$MihomoDir\Country.mmdb missing; rule mode may block waiting to download GeoIP DB."
    }
    $proc = Start-Process -FilePath $Bin -ArgumentList @("-d", $MihomoDir, "-f", $Cfg) `
        -WindowStyle Hidden -RedirectStandardOutput $LogOut -RedirectStandardError $LogErr -PassThru
    Set-Content -LiteralPath $PidFile -Value ([string]$proc.Id) -NoNewline
    for ($i = 0; $i -lt 20; $i++) {
        if (Test-TcpPort -TargetHost $ProxyHost -Port $ProxyPort) {
            Write-Host "mihomo started (pid=$($proc.Id), proxy=$ProxyAddr)"
            return
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Error "mihomo failed to bind ${ProxyHost}:${ProxyPort}; check $LogOut / $LogErr"
    Stop-Mihomo
    exit 1
}

function Stop-Mihomo {
    $runningPid = Get-RunningPid
    if ($runningPid -gt 0) {
        Stop-Process -Id $runningPid -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    } else {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
    Write-Host "mihomo stopped"
}

function Show-Status {
    $runningPid = Get-RunningPid
    if ($runningPid -gt 0) {
        Write-Host "mihomo running (pid=$runningPid, proxy=$ProxyAddr)"
    } else {
        Write-Host "mihomo stopped"
    }
}

$Action = if ($args.Count -gt 0) { [string]$args[0] } else { "status" }
switch ($Action) {
    "start"  { Start-Mihomo }
    "stop"   { Stop-Mihomo }
    "status" { Show-Status }
    "run"    {
        if ($args.Count -lt 2) {
            Write-Error "Usage: mihomo_ctl.ps1 run <command> [args...]"
            exit 2
        }
        $wasRunning = (Get-RunningPid) -gt 0
        if (-not $wasRunning) { Start-Mihomo }

        $prevHttp  = $env:HTTP_PROXY
        $prevHttps = $env:HTTPS_PROXY
        $prevNo    = $env:NO_PROXY
        $np = "127.0.0.1,localhost,::1,host.docker.internal"
        $rc = 0
        try {
            $env:HTTP_PROXY  = $ProxyAddr
            $env:HTTPS_PROXY = $ProxyAddr
            $env:http_proxy  = $ProxyAddr
            $env:https_proxy = $ProxyAddr
            $env:NO_PROXY    = $np
            $env:no_proxy    = $np

            $cmdExe = [string]$args[1]
            $cmdArgs = if ($args.Count -gt 2) { @($args[2..($args.Count - 1)]) } else { @() }
            & $cmdExe @cmdArgs
            if ($LASTEXITCODE -ne $null) { $rc = [int]$LASTEXITCODE }
        } finally {
            $env:HTTP_PROXY  = $prevHttp
            $env:HTTPS_PROXY = $prevHttps
            $env:NO_PROXY    = $prevNo
            if (-not $wasRunning) { Stop-Mihomo }
        }
        exit $rc
    }
    default {
        Write-Error "Usage: mihomo_ctl.ps1 {start|stop|status|run <command...>}"
        exit 2
    }
}
