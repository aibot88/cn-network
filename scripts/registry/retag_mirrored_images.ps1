#Requires -Version 5.1
<#
.SYNOPSIS
  Re-tag local mirror-prefixed Docker images back to canonical names (zero network).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\registry\retag_mirrored_images.ps1 --dry-run
#>
$ErrorActionPreference = "Continue"

$DryRun = $false
foreach ($a in $args) {
    switch -Regex ([string]$a) {
        '^(-DryRun|--dry-run)$'  { $DryRun = $true }
        '^(-h|--help|-Help|\?)$' {
            Write-Host "Usage: retag_mirrored_images.ps1 [--dry-run|-DryRun]"
            exit 0
        }
        default { Write-Error "Unknown argument: $a"; exit 2 }
    }
}

$MirrorsRaw  = if ($env:MIRRORS) { $env:MIRRORS } else { "docker.1ms.run docker.1panel.live docker.m.daocloud.io" }
$MirrorHosts = @($MirrorsRaw -split '\s+' | Where-Object { $_ -ne "" } | ForEach-Object { $_ -replace '^https?://', '' })

$created  = 0
$skipped  = 0
$examined = 0

Write-Host "Scanning local images for mirror-prefixed names..."
$lines = @(& docker images --format '{{.Repository}}:{{.Tag}}' 2>$null | Where-Object { $_ -and $_ -notmatch '^<none>' } | Sort-Object -Unique)

foreach ($full in $lines) {
    $examined++
    $canonical = ""
    foreach ($h in $MirrorHosts) {
        if ($full.StartsWith("$h/library/")) {
            $canonical = $full.Substring(("$h/library/").Length)
            break
        } elseif ($full.StartsWith("$h/")) {
            $canonical = $full.Substring(("$h/").Length)
            break
        }
    }
    if (-not $canonical) { continue }
    if ($canonical -match ':<none>$|^<none>:') { $skipped++; continue }

    $null = & docker image inspect $canonical 2>$null
    if ($LASTEXITCODE -eq 0) { $skipped++; continue }

    if ($DryRun) {
        Write-Host "[dry ] $full  ->  $canonical"
        continue
    }
    & docker tag $full $canonical 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[tag ] $full  ->  $canonical"
        $created++
    } else {
        Write-Error "[FAIL] could not tag $full -> $canonical"
    }
}

Write-Host "`n=============================================================="
Write-Host " examined=$examined  newly_tagged=$created  already_present=$skipped"
Write-Host "=============================================================="
