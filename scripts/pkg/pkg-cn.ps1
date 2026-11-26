#Requires -Version 5.1
<#
.SYNOPSIS
  Configure Mainland-China package mirrors natively on Windows PowerShell / CMD
  (pip, npm/pnpm/yarn, maven, gradle, cargo, conda, go, composer, gem, git).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\pkg\pkg-cn.ps1 pip
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\pkg\pkg-cn.ps1 npm --project
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\pkg\pkg-cn.ps1 maven C:\path\to\repo
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\pkg\pkg-cn.ps1 git gh-clone https://github.com/org/repo.git
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\pkg\pkg-cn.ps1 all
#>
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Backup-Once([string]$Path) {
    if (Test-Path $Path) {
        $bak = "$Path.cn-bak"
        if (-not (Test-Path $bak)) {
            Copy-Item -LiteralPath $Path -Destination $bak -Force
        }
    }
}

function Set-PipMirror([bool]$ProjectMode) {
    $index   = if ($env:PIP_INDEX_URL) { $env:PIP_INDEX_URL } else { "https://mirrors.aliyun.com/pypi/simple/" }
    $trusted = if ($env:PIP_TRUSTED_HOST) { $env:PIP_TRUSTED_HOST } else { "mirrors.aliyun.com" }
    $appData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME "AppData\Roaming" }
    $pipIni  = Join-Path $appData "pip\pip.ini"
    $pipDir  = Split-Path -Parent $pipIni
    if (-not (Test-Path $pipDir)) { New-Item -ItemType Directory -Path $pipDir -Force | Out-Null }
    Backup-Once $pipIni
    $body = "[global]`r`nindex-url = $index`r`ntrusted-host = $trusted`r`ntimeout = 60`r`nretries = 5`r`n"
    [System.IO.File]::WriteAllText($pipIni, $body, $Utf8NoBom)
    Write-Host "[pip-cn] wrote $pipIni"

    if ($ProjectMode) {
        $projIni = Join-Path (Get-Location) "pip.ini"
        [System.IO.File]::WriteAllText($projIni, $body, $Utf8NoBom)
        Write-Host "[pip-cn] wrote $projIni"
    }
    Write-Host "[pip-cn] PowerShell env (uv / HuggingFace):"
    Write-Host "  `$env:UV_INDEX_URL='$index'; `$env:HF_ENDPOINT='https://hf-mirror.com'"
}

function Write-NpmrcBlock([string]$TargetPath, [string]$Registry, [string]$BinHost) {
    $kept = New-Object System.Collections.Generic.List[string]
    if (Test-Path $TargetPath) {
        Backup-Once $TargetPath
        $skip = $false
        foreach ($line in (Get-Content -LiteralPath $TargetPath -Encoding UTF8)) {
            if ($line -match '# >>> cn-network-begin') { $skip = $true; continue }
            if ($line -match '# <<< cn-network-end')   { $skip = $false; continue }
            if (-not $skip -and ($line -notmatch '^\s*(registry|disturl|electron_mirror|sass_binary_site)\s*=')) {
                $kept.Add($line)
            }
        }
    }
    $block = @(
        "# >>> cn-network-begin (managed by cn-network/scripts/pkg/pkg-cn.ps1)",
        "registry=$Registry",
        "disturl=$BinHost/node",
        "electron_mirror=$BinHost/electron/",
        "electron_builder_binaries_mirror=$BinHost/electron-builder-binaries/",
        "sass_binary_site=$BinHost/node-sass",
        "sharp_binary_host=$BinHost/sharp",
        "sharp_libvips_binary_host=$BinHost/sharp-libvips",
        "puppeteer_download_host=$BinHost",
        "playwright_download_host=$BinHost/playwright",
        "chromedriver_cdnurl=$BinHost/chromedriver",
        "operadriver_cdnurl=$BinHost/operadriver",
        "phantomjs_cdnurl=$BinHost/phantomjs",
        "node_sqlite3_binary_host_mirror=$BinHost/node-sqlite3",
        "profiler_binary_host_mirror=$BinHost/node-inspector",
        "fund=false",
        "audit=false",
        "# <<< cn-network-end"
    )
    $all = @($kept) + $block
    [System.IO.File]::WriteAllText($TargetPath, (($all -join "`n") + "`n"), $Utf8NoBom)
    Write-Host "[npm-cn] wrote $TargetPath"
}

function Set-NpmMirror([bool]$ProjectMode) {
    $reg = if ($env:NPM_REGISTRY) { $env:NPM_REGISTRY } else { "https://registry.npmmirror.com" }
    $bin = if ($env:NPM_BIN_HOST) { $env:NPM_BIN_HOST } else { "https://npmmirror.com/mirrors" }
    if (Get-Command "yarn" -ErrorAction SilentlyContinue) { & yarn config set registry $reg 2>$null | Out-Null }
    if (Get-Command "pnpm" -ErrorAction SilentlyContinue) { & pnpm config set registry $reg 2>$null | Out-Null }
    Write-NpmrcBlock (Join-Path $HOME ".npmrc") $reg $bin
    if ($ProjectMode) {
        Write-NpmrcBlock (Join-Path (Get-Location) ".npmrc") $reg $bin
    }
}

function Set-MavenMirror([string]$ProjectDir) {
    $mirror = if ($env:MAVEN_MIRROR) { $env:MAVEN_MIRROR } else { "https://maven.aliyun.com/repository/public" }
    $m2Dir  = Join-Path $HOME ".m2"
    if (-not (Test-Path $m2Dir)) { New-Item -ItemType Directory -Path $m2Dir -Force | Out-Null }
    $settings = Join-Path $m2Dir "settings.xml"
    if ((Test-Path $settings) -and ((Get-Content -LiteralPath $settings -Raw -Encoding UTF8) -match "aliyunmaven")) {
        Write-Host "[maven-cn] $settings already contains aliyun mirror"
    } else {
        Backup-Once $settings
        $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
  <mirrors>
    <mirror>
      <id>aliyunmaven</id>
      <mirrorOf>*</mirrorOf>
      <name>Aliyun Public Repository</name>
      <url>$mirror</url>
    </mirror>
  </mirrors>
</settings>
"@
        [System.IO.File]::WriteAllText($settings, ($xml + "`n"), $Utf8NoBom)
        Write-Host "[maven-cn] wrote $settings"
    }

    if ($ProjectDir) {
        foreach ($rel in @(".mvn\wrapper\maven-wrapper.properties", "mvnw\maven-wrapper.properties")) {
            $wp = Join-Path $ProjectDir $rel
            if (Test-Path $wp) {
                Backup-Once $wp
                $content = Get-Content -LiteralPath $wp -Raw -Encoding UTF8
                $ver = ""
                if ($content -match 'apache-maven/([0-9]+\.[0-9]+(\.[0-9]+)?)/') { $ver = $Matches[1] }
                elseif ($content -match 'maven-([0-9]+\.[0-9]+(\.[0-9]+)?)-bin') { $ver = $Matches[1] }
                if ($ver) {
                    $newUrl = ($mirror.TrimEnd('/')) + "/org/apache/maven/apache-maven/$ver/apache-maven-$ver-bin.zip"
                    $patched = [regex]::Replace($content, '(?m)^distributionUrl=.*$', "distributionUrl=$newUrl")
                    [System.IO.File]::WriteAllText($wp, $patched, $Utf8NoBom)
                    Write-Host "[maven-cn] patched wrapper ($ver) in $wp"
                }
                break
            }
        }
    }
}

function Set-GradleMirror {
    $initDir = Join-Path $HOME ".gradle\init.d"
    if (-not (Test-Path $initDir)) { New-Item -ItemType Directory -Path $initDir -Force | Out-Null }
    $dst = Join-Path $initDir "cn.gradle"
    Backup-Once $dst
    Copy-Item -LiteralPath (Join-Path $ScriptDir "gradle-cn.gradle") -Destination $dst -Force
    Write-Host "[gradle-cn] installed $dst"
}

function Set-CargoMirror {
    $cargoDir = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $HOME ".cargo" }
    if (-not (Test-Path $cargoDir)) { New-Item -ItemType Directory -Path $cargoDir -Force | Out-Null }
    $dst = Join-Path $cargoDir "config.toml"
    Backup-Once $dst
    Copy-Item -LiteralPath (Join-Path $ScriptDir "cargo-cn.toml") -Destination $dst -Force
    Write-Host "[cargo-cn] installed $dst"
}

function Set-CondaMirror {
    $dst = Join-Path $HOME ".condarc"
    Backup-Once $dst
    Copy-Item -LiteralPath (Join-Path $ScriptDir "conda-cn.condarc") -Destination $dst -Force
    Write-Host "[conda-cn] installed $dst"
}

function Set-GoMirror {
    $goproxy = if ($env:GOPROXY_CN) { $env:GOPROXY_CN } else { "https://goproxy.cn,direct" }
    $gosumdb = if ($env:GOSUMDB_CN) { $env:GOSUMDB_CN } else { "sum.golang.google.cn" }
    if (Get-Command "go" -ErrorAction SilentlyContinue) {
        & go env -w "GOPROXY=$goproxy"
        & go env -w "GOSUMDB=$gosumdb"
        & go env -w "GOFLAGS=-mod=mod"
        & go env -w "GOTOOLCHAIN=local"
        Write-Host "[go-cn] configured via go env -w"
    } else {
        Write-Host "[go-cn] go not found; PowerShell env: `$env:GOPROXY='$goproxy'; `$env:GOSUMDB='$gosumdb'"
    }
}

function Set-ComposerMirror {
    $m = if ($env:COMPOSER_MIRROR) { $env:COMPOSER_MIRROR } else { "https://mirrors.aliyun.com/composer/" }
    if (Get-Command "composer" -ErrorAction SilentlyContinue) {
        & composer config -g repos.packagist composer $m
        & composer config -g process-timeout 900
        Write-Host "[composer-cn] global repos.packagist -> $m"
    } else {
        Write-Host "[composer-cn] composer not installed; skipping"
    }
}

function Set-GemMirror {
    $gemSrc = if ($env:RUBYGEMS_SOURCE) { $env:RUBYGEMS_SOURCE } else { "https://mirrors.aliyun.com/rubygems/" }
    $bndMir = if ($env:GEM_MIRROR) { $env:GEM_MIRROR } else { "https://mirrors.tuna.tsinghua.edu.cn/rubygems" }
    if (Get-Command "gem" -ErrorAction SilentlyContinue) {
        & gem sources --add $gemSrc --remove https://rubygems.org/ 2>$null | Out-Null
        Write-Host "[gem-cn] gem sources -> $gemSrc"
    }
    if (Get-Command "bundle" -ErrorAction SilentlyContinue) {
        & bundle config mirror.https://rubygems.org $bndMir 2>$null | Out-Null
        Write-Host "[gem-cn] bundle mirror -> $bndMir"
    }
}

function Invoke-GitCn([string[]]$RestArgs) {
    $prefix = if ($env:GH_PROXY_PREFIX) { $env:GH_PROXY_PREFIX } else { "https://ghfast.top/" }
    $sub = if ($RestArgs.Count -gt 0) { $RestArgs[0] } else { "tune" }
    switch ($sub) {
        "tune" {
            & git config --global http.postBuffer 524288000
            & git config --global http.lowSpeedLimit 1000
            & git config --global http.lowSpeedTime 60
            & git config --global core.compression 0
            & git config --global http.version HTTP/1.1
            Write-Host "[git-cn] tuned global git http settings"
        }
        "gh-clone" {
            if ($RestArgs.Count -lt 2) { Write-Error "Usage: pkg-cn.ps1 git gh-clone <url> [dest]"; exit 2 }
            $url  = $RestArgs[1]
            $dest = if ($RestArgs.Count -gt 2) { $RestArgs[2] } else { "" }
            if ($url -match '^https://github\.com/') {
                Write-Host "[git-cn] trying direct clone: $url"
                if ($dest) { & git clone --depth 1 $url $dest 2>$null } else { & git clone --depth 1 $url 2>$null }
                if ($LASTEXITCODE -eq 0) { Write-Host "[git-cn] direct clone OK"; return }
                $proxied = "$prefix$url"
                Write-Host "[git-cn] retrying via prefix: $proxied"
                if ($dest) { & git clone --depth 1 $proxied $dest } else { & git clone --depth 1 $proxied }
                if ($LASTEXITCODE -ne 0) { exit 1 }
            } else {
                if ($dest) { & git clone --depth 1 $url $dest } else { & git clone --depth 1 $url }
            }
        }
        "gh-tar" {
            if ($RestArgs.Count -lt 2) { Write-Error "Usage: pkg-cn.ps1 git gh-tar <url> <outFile>"; exit 2 }
            $proxied = "$prefix$($RestArgs[1])"
            $outFile = if ($RestArgs.Count -gt 2) { $RestArgs[2] } else { Split-Path -Leaf $RestArgs[1] }
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $proxied -OutFile $outFile -UseBasicParsing
            Write-Host "[git-cn] saved $outFile"
        }
        default {
            Write-Error "Unknown git subcommand '$sub' (expected: tune | gh-clone | gh-tar)"
            exit 2
        }
    }
}

$Target = if ($args.Count -gt 0) { [string]$args[0] } else { "-h" }
$ProjectMode = ($args -contains "--project") -or ($args -contains "-Project")
$Rest = @($args | Select-Object -Skip 1 | Where-Object { $_ -notin @("--project", "-Project") })

switch -Regex ($Target) {
    '^pip$'      { Set-PipMirror $ProjectMode }
    '^npm$'      { Set-NpmMirror $ProjectMode }
    '^maven$'    { Set-MavenMirror (if ($Rest.Count -gt 0) { [string]$Rest[0] } else { "" }) }
    '^gradle$'   { Set-GradleMirror }
    '^cargo$'    { Set-CargoMirror }
    '^conda$'    { Set-CondaMirror }
    '^go$'       { Set-GoMirror }
    '^composer$' { Set-ComposerMirror }
    '^gem$'      { Set-GemMirror }
    '^git$'      { Invoke-GitCn $Rest }
    '^all$'      {
        Set-PipMirror $ProjectMode
        Set-NpmMirror $ProjectMode
        Set-MavenMirror ""
        Set-GradleMirror
        Set-CargoMirror
        Set-CondaMirror
        Set-GoMirror
        Set-ComposerMirror
        Set-GemMirror
        Invoke-GitCn @("tune")
    }
    default {
        Write-Host "Usage: pkg-cn.ps1 <pip|npm|maven|gradle|cargo|conda|go|composer|gem|git|all> [--project] [args...]"
        exit 0
    }
}
