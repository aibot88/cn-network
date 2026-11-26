#Requires -Version 5.1
<#
.SYNOPSIS
  Safely merge Mainland-China DNS & registry-mirrors into Docker daemon.json on Windows
  (Docker Desktop or Windows Server Docker Engine), preserving all existing keys.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup_docker_cn.ps1 --dry-run
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup_docker_cn.ps1
  $env:MIRRORS="https://docker.1ms.run https://docker.1panel.live"; .\scripts\setup_docker_cn.ps1 -Restart
#>
$ErrorActionPreference = "Stop"

$DryRun = $false
$DoRestart = $false
$CustomFile = $env:DAEMON_JSON

for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    switch -Regex ($a) {
        '^(-DryRun|--dry-run)$'       { $DryRun = $true }
        '^(-Restart|--restart)$'      { $DoRestart = $true }
        '^(-NoRestart|--no-restart)$' { $DoRestart = $false }
        '^(-File|--file)$'            { $i++; $CustomFile = [string]$args[$i] }
        '^--file=(.+)$'               { $CustomFile = $Matches[1] }
        '^(-h|--help|-Help|\?)$'      {
            Write-Host "Usage: setup_docker_cn.ps1 [--dry-run|-DryRun] [--restart|-Restart] [--file <daemon.json>]"
            Write-Host "Env  : MIRRORS='https://docker.1ms.run ...'  DNS_SERVERS='223.5.5.5 119.29.29.29'"
            exit 0
        }
        default {
            Write-Error "Unknown argument: $a"
            exit 2
        }
    }
}

$MirrorsRaw = if ($env:MIRRORS) { $env:MIRRORS } else { "https://docker.1ms.run https://docker.1panel.live https://docker.m.daocloud.io" }
$DnsRaw     = if ($env:DNS_SERVERS) { $env:DNS_SERVERS } else { "223.5.5.5 119.29.29.29" }

$DesiredMirrors = @($MirrorsRaw -split '\s+' | Where-Object { $_ -ne "" })
$DesiredDns     = @($DnsRaw -split '\s+' | Where-Object { $_ -ne "" })

if ($CustomFile) {
    $TargetJson = $CustomFile
} else {
    $UserDockerJson = Join-Path $HOME ".docker\daemon.json"
    $ProgData = if ($env:ProgramData) { $env:ProgramData } else { "C:\ProgramData" }
    $ServerDockerJson = Join-Path $ProgData "docker\config\daemon.json"
    $DockerDesktopDir = Join-Path $HOME ".docker"

    if ((Test-Path $UserDockerJson) -or (Test-Path $DockerDesktopDir) -or -not (Test-Path $ServerDockerJson)) {
        $TargetJson = $UserDockerJson
    } else {
        $TargetJson = $ServerDockerJson
    }
}

# Convert PSCustomObject recursively into an ordered hashtable so Windows PowerShell 5.1 can mutate keys cleanly
function ConvertTo-OrderedMap($obj) {
    if ($null -eq $obj) { return [ordered]@{} }
    if ($obj -is [System.Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($k in $obj.Keys) { $map[$k] = ConvertTo-OrderedMap $obj[$k] }
        return $map
    }
    if ($obj -is [pscustomobject]) {
        $map = [ordered]@{}
        foreach ($prop in $obj.PSObject.Properties) {
            $map[$prop.Name] = ConvertTo-OrderedMap $prop.Value
        }
        return $map
    }
    if (($obj -is [System.Collections.IEnumerable]) -and -not ($obj -is [string])) {
        $arr = New-Object System.Collections.ArrayList
        foreach ($item in $obj) { [void]$arr.Add((ConvertTo-OrderedMap $item)) }
        return ,$arr.ToArray()
    }
    return $obj
}

$Data = [ordered]@{}
if (Test-Path $TargetJson) {
    $Raw = (Get-Content -LiteralPath $TargetJson -Raw -Encoding UTF8).Trim()
    if ($Raw.Length -gt 0) {
        $Parsed = $Raw | ConvertFrom-Json
        $Data = ConvertTo-OrderedMap $Parsed
    }
}

$ExistingDns = New-Object System.Collections.Generic.List[string]
if ($Data.Contains("dns") -and $null -ne $Data["dns"]) {
    foreach ($x in @($Data["dns"])) {
        $s = [string]$x
        if ($s -and -not $ExistingDns.Contains($s)) { $ExistingDns.Add($s) }
    }
}
foreach ($ip in $DesiredDns) {
    if (-not $ExistingDns.Contains($ip)) { $ExistingDns.Add($ip) }
}
$Data["dns"] = @($ExistingDns)

$ExistingMirrors = New-Object System.Collections.Generic.List[string]
if ($Data.Contains("registry-mirrors") -and $null -ne $Data["registry-mirrors"]) {
    foreach ($x in @($Data["registry-mirrors"])) {
        $s = [string]$x
        if ($s -and -not $ExistingMirrors.Contains($s)) { $ExistingMirrors.Add($s) }
    }
}
foreach ($m in $DesiredMirrors) {
    if (-not $ExistingMirrors.Contains($m)) { $ExistingMirrors.Add($m) }
}
$Data["registry-mirrors"] = @($ExistingMirrors)

$Rendered = ($Data | ConvertTo-Json -Depth 20) + "`n"
# Validate JSON round-trip strictly before writing
$null = $Rendered | ConvertFrom-Json

if ($DryRun) {
    Write-Host "[dry-run] target: $TargetJson"
    Write-Host "[dry-run] merged daemon.json would be:"
    Write-Host $Rendered
    exit 0
}

$TargetDir = Split-Path -Parent $TargetJson
if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

if (Test-Path $TargetJson) {
    $Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $BackupPath = Join-Path ([System.IO.Path]::GetTempPath()) "daemon.json.cn-bak.$Stamp"
    Copy-Item -LiteralPath $TargetJson -Destination $BackupPath -Force
    Write-Host "Backed up existing $TargetJson -> $BackupPath"
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($TargetJson, $Rendered, $Utf8NoBom)
Write-Host "Updated ${TargetJson}:"
Write-Host $Rendered

if ($DoRestart) {
    $Svc = Get-Service -Name "docker" -ErrorAction SilentlyContinue
    if ($Svc) {
        Restart-Service -Name "docker" -Force
        Write-Host "Restarted Windows 'docker' service."
    } else {
        $DesktopExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
        if (Test-Path $DesktopExe) {
            Get-Process "Docker Desktop" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            Start-Process -FilePath $DesktopExe
            Write-Host "Restarting Docker Desktop (allow ~20-40s for engine readiness)..."
        } else {
            Write-Host "NOTE: Please restart Docker Desktop from the system tray to apply changes."
        }
    }
} else {
    Write-Host "NOTE: Restart Docker Desktop (or pass -Restart) to apply updated daemon.json."
}
