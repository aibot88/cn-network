#Requires -Version 5.1
<#
.SYNOPSIS
  Pull a Docker image through Mainland-China mirrors with fallback, verify
  architecture, and re-tag to canonical image name (Windows PowerShell / CMD).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\registry\pull_with_fallback.ps1 redis:6-alpine
  .\scripts\registry\pull_with_fallback.ps1 ghcr.io/org/img:v1 --platform linux/amd64
#>
$ErrorActionPreference = "Continue"

$MirrorsRaw = if ($env:MIRRORS) { $env:MIRRORS } else { "docker.1ms.run docker.1panel.live docker.m.daocloud.io" }
$Mirrors    = @($MirrorsRaw -split '\s+' | Where-Object { $_ -ne "" })
$Platform   = ""
$Ref        = ""

for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    switch -Regex ($a) {
        '^(-Platform|--platform)$' { $i++; $Platform = [string]$args[$i] }
        '^--platform=(.+)$'        { $Platform = $Matches[1] }
        '^(-h|--help|-Help|\?)$'   {
            Write-Host "Usage: pull_with_fallback.ps1 <image[:tag]> [--platform linux/amd64]"
            exit 0
        }
        '^-' { Write-Error "Unknown option: $a"; exit 2 }
        default { $Ref = $a }
    }
}

if (-not $Ref) { Write-Error "Missing image reference (e.g. redis:6-alpine)"; exit 2 }
if (-not (Get-Command "docker" -ErrorAction SilentlyContinue)) { Write-Error "docker CLI not found"; exit 2 }

$First = ($Ref -split '/', 2)[0]
if (($Ref -match '/') -and (($First -match '\.') -or ($First -match ':') -or ($First -eq 'localhost'))) {
    $OriginHost = $First
    $Rest       = ($Ref -split '/', 2)[1]
    $BareRef    = $Ref
    $Canonical  = $Ref
} else {
    $OriginHost = "docker.io"
    $Rest       = $Ref
    $Canonical  = if ($Ref -match '/') { "docker.io/$Ref" } else { "docker.io/library/$Ref" }
    $BareRef    = $Ref
}

$LastColon = $Rest.LastIndexOf(':')
$LastSlash = $Rest.LastIndexOf('/')
if ($LastColon -le $LastSlash) {
    $Rest = "${Rest}:latest"
}

Write-Host "[pull] target      : $Ref"
Write-Host "[pull] canonical   : $Canonical"
Write-Host "[pull] origin host : $OriginHost"
if ($Platform) { Write-Host "[pull] platform    : $Platform" }

$Candidates = New-Object System.Collections.Generic.List[string]
if ($OriginHost -eq "docker.io") {
    $null = & docker image inspect $Canonical 2>$null
    $hasCanon = ($LASTEXITCODE -eq 0)
    $null = & docker image inspect $BareRef 2>$null
    $hasBare = ($LASTEXITCODE -eq 0)
    if ($hasCanon -or $hasBare) {
        Write-Host "[pull] already present locally, nothing to do"
        exit 0
    }
    foreach ($m in $Mirrors) {
        if ($Rest -match '/') { $Candidates.Add("$m/$Rest") }
        else { $Candidates.Add("$m/library/$Rest") }
    }
    $Candidates.Add($Canonical)
} else {
    if ($env:NONHUB_PREFIXES) {
        foreach ($p in @($env:NONHUB_PREFIXES -split '\s+' | Where-Object { $_ -ne "" })) {
            $Candidates.Add("$p/$Rest")
        }
    }
    $Candidates.Add($Canonical)
}

$Pulled = ""
foreach ($cand in $Candidates) {
    Write-Host "[pull] trying: $cand"
    if ($Platform) {
        & docker pull --platform $Platform $cand
    } else {
        & docker pull $cand
    }
    if ($LASTEXITCODE -eq 0) {
        $Pulled = $cand
        break
    }
    Write-Host "[pull]   -> failed, next"
}

if (-not $Pulled) {
    Write-Error "[pull] ALL CANDIDATES FAILED for $Ref"
    Write-Host "       - configure daemon.json registry-mirrors (scripts\setup_docker_cn.ps1)"
    Write-Host "       - for ghcr.io/quay.io/gcr.io/mcr: set `$env:NONHUB_PREFIXES"
    Write-Host "       - last resort: .\scripts\mihomo_ctl.ps1 run docker pull $Canonical"
    exit 1
}

$Arch = ((& docker image inspect --format '{{.Architecture}}' $Pulled 2>$null) -join "").Trim()
if (-not $Arch) { $Arch = "unknown" }
Write-Host "[pull] pulled arch: $Arch"
if ($Platform) {
    $Want = $Platform -replace '^linux/', ''
    if ($Arch -ne "unknown" -and $Arch -ne $Want) {
        Write-Warning "[pull] expected $Want but image arch is $Arch"
    }
}

if ($Pulled -ne $Canonical) {
    & docker tag $Pulled $Canonical
    Write-Host "[pull] tagged $Pulled -> $Canonical"
}
if ($Canonical -ne $Ref) {
    & docker tag $Pulled $Ref 2>$null
}
Write-Host "[pull] OK: $Ref  (from $Pulled)"
