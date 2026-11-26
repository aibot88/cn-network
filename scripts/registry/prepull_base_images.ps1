#Requires -Version 5.1
<#
.SYNOPSIS
  Pre-pull common web-stack base images through Mainland-China mirrors on Windows.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\registry\prepull_base_images.ps1 --dry-run
  .\scripts\registry\prepull_base_images.ps1 --java-only
#>
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Puller    = Join-Path $ScriptDir "pull_with_fallback.ps1"
if (-not (Test-Path $Puller)) { Write-Error "Missing $Puller"; exit 1 }

$DryRun   = $false
$JavaOnly = $false
foreach ($a in $args) {
    switch -Regex ([string]$a) {
        '^(-DryRun|--dry-run)$'     { $DryRun = $true }
        '^(-JavaOnly|--java-only)$' { $JavaOnly = $true }
        '^(-h|--help|-Help|\?)$'    {
            Write-Host "Usage: prepull_base_images.ps1 [--dry-run|-DryRun] [--java-only|-JavaOnly]"
            exit 0
        }
        default { Write-Error "Unknown argument: $a"; exit 2 }
    }
}

$JavaImages = @(
    "eclipse-temurin:17-jre", "eclipse-temurin:21-jre",
    "maven:3.9-eclipse-temurin-17", "maven:3.9-eclipse-temurin-21"
)
$DataImages = @(
    "mysql:8.0", "mariadb:10.11", "postgres:16-alpine",
    "redis:7.2-alpine", "rabbitmq:3.13-management"
)
$WebImages = @(
    "nginx:alpine", "node:20-bookworm-slim", "node:22-bookworm-slim",
    "python:3.11-slim", "python:3.12-slim", "golang:1.22-alpine", "php:8.2-fpm"
)
$UtilImages = @("busybox:1.36", "alpine:3.20", "curlimages/curl:8.8.0")

function Invoke-PullGroup([string]$GroupName, [string[]]$Images) {
    Write-Host "`n=============================================================="
    Write-Host " Group: $GroupName  ($($Images.Count) images)"
    Write-Host "=============================================================="
    $ok = 0; $skip = 0; $failed = @()
    foreach ($img in $Images) {
        $null = & docker image inspect $img 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[skip] $img (already present)"
            $skip++
            continue
        }
        if ($DryRun) {
            Write-Host "[dry ] would pull: $img"
            continue
        }
        & powershell -NoProfile -ExecutionPolicy Bypass -File $Puller $img
        if ($LASTEXITCODE -eq 0) { $ok++ } else { $failed += $img }
    }
    Write-Host "--- ${GroupName}: pulled=$ok skipped=$skip failed=$($failed.Count)"
    if ($failed.Count -gt 0) {
        Write-Host ("    FAILED: " + ($failed -join " "))
        return $false
    }
    return $true
}

$allOk = $true
if ($JavaOnly) {
    if (-not (Invoke-PullGroup "JAVA" $JavaImages)) { $allOk = $false }
} else {
    if (-not (Invoke-PullGroup "JAVA" $JavaImages)) { $allOk = $false }
    if (-not (Invoke-PullGroup "DATA" $DataImages)) { $allOk = $false }
    if (-not (Invoke-PullGroup "WEB"  $WebImages))  { $allOk = $false }
    if (-not (Invoke-PullGroup "UTIL" $UtilImages)) { $allOk = $false }
}

if (-not $allOk) {
    Write-Host "Some images failed. Re-run, or pull with: .\scripts\mihomo_ctl.ps1 run docker pull <image>"
    exit 1
}
Write-Host "All base images ready."
