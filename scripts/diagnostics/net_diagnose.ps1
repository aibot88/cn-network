#Requires -Version 5.1
<#
.SYNOPSIS
  One-shot Mainland-China network health check for Windows PowerShell / CMD.
  Covers host DNS, HTTPS egress, Docker daemon, container DNS/egress, MTU,
  clock skew, domestic package mirrors, GitHub/ghfast, and LLM API endpoint.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diagnostics\net_diagnose.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diagnostics\net_diagnose.ps1 --json --quick
#>
$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$JsonMode = $false
$Quick    = $false
foreach ($a in $args) {
    switch -Regex ([string]$a) {
        '^(-Json|--json)$'   { $JsonMode = $true }
        '^(-Quick|--quick)$' { $Quick = $true }
        '^(-h|--help|-Help|\?)$' {
            Write-Host "Usage: net_diagnose.ps1 [--json|-Json] [--quick|-Quick]"
            exit 0
        }
    }
}

$script:Fails = 0
$script:Warns = 0
$script:Rows  = New-Object System.Collections.Generic.List[object]

function Add-Check([string]$Status, [string]$Name, [string]$Detail) {
    $script:Rows.Add([ordered]@{ status = $Status; check = $Name; detail = $Detail })
    if ($Status -eq "FAIL") { $script:Fails++ }
    elseif ($Status -eq "WARN") { $script:Warns++ }
    if (-not $JsonMode) {
        $color = switch ($Status) {
            "PASS" { "Green" }
            "WARN" { "Yellow" }
            "FAIL" { "Red" }
            default { "Cyan" }
        }
        Write-Host -NoNewline "  "
        Write-Host -NoNewline $Status -ForegroundColor $color
        Write-Host (" {0,-32} {1}" -f $Name, $Detail)
    }
}

function Write-Header([string]$Title) {
    if (-not $JsonMode) { Write-Host "`n== $Title ==" -ForegroundColor White }
}

function Get-HttpStatus([string]$Url, [int]$TimeoutSec = 8) {
    $curlExe = Get-Command "curl.exe" -ErrorAction SilentlyContinue
    if ($curlExe) {
        $code = & $curlExe.Source -sS -o NUL -w "%{http_code}" --max-time $TimeoutSec $Url 2>$null
        if ($code) { return [string]$code }
        return "000"
    }
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        return [string]([int]$resp.StatusCode)
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            return [string]([int]$_.Exception.Response.StatusCode)
        }
        return "000"
    }
}

Add-Check "INFO" "host:platform" ("windows ({0})" -f [System.Environment]::OSVersion.VersionString)

# ------------------------------------------------------------------ 1. Host DNS
Write-Header "1. Host DNS"
foreach ($h in @("mirrors.aliyun.com", "registry-1.docker.io", "github.com")) {
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($h)
        if ($addrs -and $addrs.Count -gt 0) {
            Add-Check "PASS" "dns:$h" $addrs[0].IPAddressToString
        } else { throw "empty" }
    } catch {
        if ($h -eq "mirrors.aliyun.com") {
            Add-Check "FAIL" "dns:$h" "cannot resolve"
        } else {
            Add-Check "WARN" "dns:$h" "cannot resolve (expected if blocked)"
        }
    }
}

if (Get-Command "Get-DnsClientServerAddress" -ErrorAction SilentlyContinue) {
    try {
        $dnsList = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.ServerAddresses.Count -gt 0 } |
            ForEach-Object { $_.ServerAddresses } | Select-Object -Unique -First 4)
        if ($dnsList.Count -gt 0) {
            Add-Check "INFO" "host:dns-servers" ($dnsList -join ", ")
        }
    } catch {}
}

# ---------------------------------------------------------- 2. Host egress
Write-Header "2. Host egress (HTTPS)"
function Test-Endpoint([string]$Name, [string]$Url, [int]$TimeoutSec, [string]$Severity) {
    $code = Get-HttpStatus -Url $Url -TimeoutSec $TimeoutSec
    if ($code -eq "000") {
        if ($Severity -eq "fail") { Add-Check "FAIL" "https:$Name" "no response within ${TimeoutSec}s" }
        else { Add-Check "WARN" "https:$Name" "no response (may be expected)" }
    } else {
        Add-Check "PASS" "https:$Name" "HTTP $code"
    }
}
Test-Endpoint "aliyun-mirror" "https://mirrors.aliyun.com/" 8 "fail"
Test-Endpoint "maven-aliyun"  "https://maven.aliyun.com/repository/public/" 8 "fail"
Test-Endpoint "npm-npmmirror" "https://registry.npmmirror.com/" 8 "fail"
Test-Endpoint "pypi-aliyun"   "https://mirrors.aliyun.com/pypi/simple/" 8 "fail"
if (-not $Quick) {
    Test-Endpoint "github"     "https://github.com/" 8 "warn"
    Test-Endpoint "docker-hub" "https://registry-1.docker.io/v2/" 8 "warn"
    Test-Endpoint "ghcr"       "https://ghcr.io/v2/" 8 "warn"
}

# ------------------------------------------------------------ 3. Docker daemon
Write-Header "3. Docker daemon"
$dockerCmd = Get-Command "docker" -ErrorAction SilentlyContinue
$dockerOk = $false
if ($dockerCmd) {
    $null = & docker info 2>$null
    if ($LASTEXITCODE -eq 0) {
        $dockerOk = $true
        Add-Check "PASS" "docker:daemon" "reachable"
        $mirrors = (& docker info --format '{{join .RegistryConfig.Mirrors ","}}' 2>$null) -join ""
        if ($mirrors) { Add-Check "PASS" "docker:mirrors" $mirrors }
        else { Add-Check "WARN" "docker:mirrors" "none configured (run scripts\setup_docker_cn.ps1)" }
        $ver = (& docker info --format '{{.ServerVersion}}' 2>$null) -join ""
        Add-Check "INFO" "docker:version" $ver
    } else {
        Add-Check "FAIL" "docker:daemon" "cannot talk to daemon (is Docker Desktop running?)"
    }
} else {
    Add-Check "WARN" "docker:cli" "docker CLI not installed"
}

$DaemonJson = if ($env:CN_DOCKER_DAEMON_JSON) { $env:CN_DOCKER_DAEMON_JSON } else { Join-Path $HOME ".docker\daemon.json" }
if (-not (Test-Path $DaemonJson)) {
    $progData = if ($env:ProgramData) { $env:ProgramData } else { "C:\ProgramData" }
    $altJson = Join-Path $progData "docker\config\daemon.json"
    if (Test-Path $altJson) { $DaemonJson = $altJson }
}
if (Test-Path $DaemonJson) {
    try {
        $parsed = (Get-Content -LiteralPath $DaemonJson -Raw -Encoding UTF8) | ConvertFrom-Json
        Add-Check "PASS" "daemon.json:valid" "$DaemonJson parses"
        if ($parsed.PSObject.Properties["proxies"] -and $null -ne $parsed.proxies) {
            $np = [string]$parsed.proxies.'no-proxy'
            if ($np -match "127\.0\.0\.1") {
                Add-Check "PASS" "daemon.json:no-proxy" "loopback not proxied"
            } else {
                Add-Check "FAIL" "daemon.json:no-proxy" "proxies set WITHOUT 127.0.0.1 in no-proxy -> local calls will break"
            }
        } else {
            Add-Check "PASS" "daemon.json:no-proxy" "loopback not proxied"
        }
    } catch {
        Add-Check "FAIL" "daemon.json:valid" "$DaemonJson is INVALID JSON -> Docker Engine will not start"
    }
} else {
    Add-Check "WARN" "daemon.json" "absent at $DaemonJson (run scripts\setup_docker_cn.ps1)"
}

# ------------------------------------------------------- 4. Container runtime
Write-Header "4. Container DNS / egress / MTU"
if ($dockerOk) {
    $img = "busybox:1.36"
    $null = & docker image inspect $img 2>$null
    if ($LASTEXITCODE -ne 0) {
        $null = & docker pull -q $img 2>$null
        if ($LASTEXITCODE -ne 0) { $img = "" }
    }
    if ($img) {
        $out = (& docker run --rm $img nslookup mirrors.aliyun.com 2>&1) -join " "
        if ($LASTEXITCODE -eq 0) {
            Add-Check "PASS" "container:dns" "busybox resolved mirrors.aliyun.com"
        } else {
            Add-Check "FAIL" "container:dns" ("resolution failed: " + $out.Substring(0, [Math]::Min(100, $out.Length)))
        }
        $eg = (& docker run --rm $img sh -c "wget -q -T 8 -O /dev/null https://mirrors.aliyun.com/ && echo ok" 2>&1) -join " "
        if ($LASTEXITCODE -eq 0 -and $eg -match "ok") {
            Add-Check "PASS" "container:egress" "https to aliyun OK"
        } else {
            Add-Check "WARN" "container:egress" "wget check inconclusive - verify manually"
        }
    } else {
        Add-Check "WARN" "container:image" "could not obtain busybox to probe container networking"
    }
} else {
    Add-Check "WARN" "container:probe" "skipped (docker unavailable)"
}

if (Get-Command "Get-NetIPInterface" -ErrorAction SilentlyContinue) {
    try {
        $vpnIf = @(Get-NetIPInterface -AddressFamily IPv4 -ConnectionState Connected -ErrorAction Stop |
            Where-Object { $_.NlMtu -lt 1480 -and $_.InterfaceAlias -notmatch "Loopback" })
        if ($vpnIf.Count -gt 0) {
            $sample = $vpnIf[0]
            Add-Check "INFO" "host:interface-mtu" ("{0} MTU={1} (consider Docker mtu=1400 if large responses stall)" -f $sample.InterfaceAlias, $sample.NlMtu)
        }
    } catch {}
}

# --------------------------------------------------------------- 5. Clock skew
Write-Header "5. Clock (TLS validity window)"
$bestSkew = $null
$bestSrc  = ""
foreach ($probe in @("https://www.baidu.com/", "https://registry.npmmirror.com/", "https://mirrors.aliyun.com/")) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($probe)
        $req.Method = "HEAD"
        $req.Timeout = 6000
        $resp = $req.GetResponse()
        $dateHdr = $resp.Headers["Date"]
        $resp.Close()
        if ($dateHdr) {
            $remoteUtc = [DateTimeOffset]::Parse($dateHdr).UtcDateTime
            $skew = [int][Math]::Abs(([DateTime]::UtcNow - $remoteUtc).TotalSeconds)
            if ($null -eq $bestSkew -or $skew -lt $bestSkew) {
                $bestSkew = $skew
                $bestSrc  = $probe
            }
        }
    } catch {}
}
if ($null -ne $bestSkew) {
    if ($bestSkew -le 60) {
        Add-Check "PASS" "clock:skew" "${bestSkew}s (best of 3 peers, via $bestSrc)"
    } else {
        Add-Check "FAIL" "clock:skew" "${bestSkew}s -> run 'w32tm /resync' in elevated PowerShell or TLS will fail"
    }
} else {
    Add-Check "WARN" "clock:skew" "no reliable Date header from any probe host"
}

# --------------------------------------------------------- 6. Language indices
if (-not $Quick) {
    Write-Header "6. Language package indices (domestic mirrors)"
    $pairs = @(
        @("apt",      "https://mirrors.aliyun.com/debian/dists/bookworm/Release"),
        @("alpine",   "https://mirrors.aliyun.com/alpine/v3.20/main/x86_64/APKINDEX.tar.gz"),
        @("maven",    "https://maven.aliyun.com/repository/public/org/apache/maven/maven-core/maven-metadata.xml"),
        @("npm",      "https://registry.npmmirror.com/lodash"),
        @("pypi",     "https://mirrors.aliyun.com/pypi/simple/requests/"),
        @("composer", "https://mirrors.aliyun.com/composer/packages.json"),
        @("goproxy",  "https://goproxy.cn/github.com/gin-gonic/gin/@v/list"),
        @("crates",   "https://rsproxy.cn/index/config.json")
    )
    foreach ($p in $pairs) {
        $code = Get-HttpStatus -Url $p[1] -TimeoutSec 8
        if ($code -match "^[23]") { Add-Check "PASS" ("pkg:" + $p[0]) "HTTP $code" }
        else { Add-Check "WARN" ("pkg:" + $p[0]) "HTTP $code" }
    }
}

# ---------------------------------------------------------------- 7. Git/GitHub
if (-not $Quick) {
    Write-Header "7. Git / GitHub reachability"
    $gh = Get-HttpStatus -Url "https://github.com/" -TimeoutSec 8
    if ($gh -match "^[234]") { Add-Check "PASS" "git:github" "HTTP $gh" }
    else { Add-Check "WARN" "git:github" "unreachable -> use ghfast prefix or mihomo_ctl.ps1 run" }
    $gf = Get-HttpStatus -Url "https://ghfast.top/https://github.com/" -TimeoutSec 8
    if ($gf -match "^[23]") { Add-Check "PASS" "git:ghfast-prefix" "HTTP $gf" }
    else { Add-Check "INFO" "git:ghfast-prefix" "HTTP $gf (may still work for real asset paths)" }
}

# ------------------------------------------------------------ 8. LLM endpoint
Write-Header "8. LLM API endpoint"
$LlmBase = if ($env:CN_LLM_BASE_URL) { $env:CN_LLM_BASE_URL } elseif ($env:OPENAI_BASE_URL) { $env:OPENAI_BASE_URL } elseif ($env:LLM_BASE_URL) { $env:LLM_BASE_URL } else { "" }
if (-not $LlmBase) {
    foreach ($envFile in @((Join-Path (Get-Location) ".env"), (Join-Path (Get-Location) "..\.env"))) {
        if (Test-Path $envFile) {
            $line = Get-Content -LiteralPath $envFile -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '^(CN_LLM_BASE_URL|OPENAI_BASE_URL|LLM_BASE_URL)=' } |
                Select-Object -First 1
            if ($line) {
                $LlmBase = (($line -split '=', 2)[1]).Trim().Trim('"').Trim("'")
                Add-Check "INFO" "llm:source" $envFile
                break
            }
        }
    }
}
if ($LlmBase) {
    $modelsUrl = ($LlmBase.TrimEnd('/')) + "/models"
    $code = Get-HttpStatus -Url $modelsUrl -TimeoutSec 10
    if ($code -match "^(2|3|401)") {
        Add-Check "PASS" "llm:reachable" "HTTP $code (401 = reachable, auth needed)"
    } elseif ($code -eq "000") {
        Add-Check "FAIL" "llm:unreachable" "$LlmBase (timeout or TLS error)"
    } else {
        Add-Check "WARN" "llm:status" "HTTP $code"
    }
} else {
    Add-Check "INFO" "llm:endpoint" "CN_LLM_BASE_URL / OPENAI_BASE_URL not set (skipped)"
}

# ------------------------------------------------------------------- Summary
Write-Header "Summary"
if ($JsonMode) {
    $payload = [ordered]@{
        fails  = $script:Fails
        warns  = $script:Warns
        checks = @($script:Rows)
    }
    Write-Output ($payload | ConvertTo-Json -Depth 10)
} else {
    Write-Host ("  FAIL={0}  WARN={1}  total={2}" -f $script:Fails, $script:Warns, $script:Rows.Count)
    if ($script:Fails -gt 0) {
        Write-Host "`n  Action required: fix FAIL items above (see references\troubleshooting.md)." -ForegroundColor Red
    } elseif ($script:Warns -gt 0) {
        Write-Host "`n  Mostly healthy. WARN items are usually non-blocking (blocked foreign hosts are expected)." -ForegroundColor Yellow
    } else {
        Write-Host "`n  All checks passed." -ForegroundColor Green
    }
}
if ($script:Fails -gt 0) { exit 1 } else { exit 0 }
