# 深度排障：症状 → 根因 → 处置（macOS / Linux / Windows）

## A. 分层验证顺序（自上而下，勿跳步）

### macOS / Linux / WSL2 / Git Bash
```bash
SKILL=~/.config/opencode/skills/cn-network
bash "$SKILL/scripts/diagnostics/net_diagnose.sh"          # 完整 8 层体检
bash "$SKILL/scripts/diagnostics/net_diagnose.sh" --quick  # 跳过慢检查
bash "$SKILL/scripts/diagnostics/net_diagnose.sh" --json   # 机器可读 JSON
```

### Windows PowerShell / CMD
```powershell
$SKILL = "$HOME\.config\opencode\skills\cn-network"
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\diagnostics\net_diagnose.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\diagnostics\net_diagnose.ps1" --quick
```

手动逐层核验对照表：

| 层级 | Linux | macOS | Windows PowerShell |
| :--- | :--- | :--- | :--- |
| 1. 宿主 DNS | `getent hosts mirrors.aliyun.com` | `dscacheutil -q host -a name mirrors.aliyun.com` | `Resolve-DnsName mirrors.aliyun.com` |
| 2. 宿主出网 | `curl -sSI --max-time 8 https://mirrors.aliyun.com/` | 同左 | `curl.exe -sSI --max-time 8 https://mirrors.aliyun.com/` |
| 3. daemon 镜像 | `docker info --format '{{.RegistryConfig.Mirrors}}'` | 同左 | 同左 |
| 4. 镜像拉取 | `docker pull busybox:1.36` | 同左 | 同左 |
| 5. BuildKit DNS | `printf 'FROM busybox\nRUN nslookup maven.aliyun.com\n' \| docker build -f - .` | 同左 | `"FROM busybox`nRUN nslookup maven.aliyun.com" \| docker build -f - .` |
| 6. 容器 DNS | `docker run --rm busybox:1.36 nslookup maven.aliyun.com` | 同左 | 同左 |
| 7. 容器出网 | `docker run --rm busybox:1.36 wget -qO- https://mirrors.aliyun.com/ \| head -c 50` | 同左 | `docker run --rm busybox:1.36 wget -q -O /dev/null https://mirrors.aliyun.com/` |

`FAIL` 必须清零；`WARN` 多为境外站点直连受阻的预期提示。

---

## B. 症状索引

### B1 `Temporary failure in name resolution` / `Name or service not known`

| 场景 | 根因 | 处置 |
| :--- | :--- | :--- |
| `docker run` 解析失败 | Linux 宿主用 `systemd-resolved`（`127.0.0.53` 桩），daemon 未配 `dns` | 运行 `setup_docker_cn.sh` / `setup_docker_cn.ps1`；或 compose 加 `dns: [223.5.5.5, 119.29.29.29]` |
| `docker build` 的 `RUN` 失败，但 `docker pull` 正常 | **BuildKit 使用独立 resolver，Linux 下不读 `/etc/docker/daemon.json`** | Linux 装 `/etc/buildkit/buildkitd.toml`；macOS / Windows / Linux 通用：`docker buildx create --use --name cn-builder --config scripts/docker/buildkitd.toml` |
| WSL2 里改了 `/etc/docker/daemon.json` 不生效 | Docker Desktop WSL2 后端读取的是 Windows 侧 `%USERPROFILE%\.docker\daemon.json` | 直接跑 `setup_docker_cn.sh`（自动识别 `/mnt/c/Users/<User>/.docker/daemon.json`）或在 Windows 跑 `setup_docker_cn.ps1`，随后重启 Docker Desktop |
| 宿主自身解析失败 | VPN/代理客户端异常退出后残留损坏的 DNS 配置 | Linux 查 `/etc/resolv.conf`；macOS 查 `scutil --dns` / 网络偏好设置；Windows 跑 `ipconfig /flushdns` 并检查网卡 DNS |

### B2 `TLS handshake timeout` / `EOF` / `connection reset`（拉镜像）

| 根因 | 处置 |
| :--- | :--- |
| `registry-1.docker.io` / `auth.docker.io` 阻断或限速 | 运行 `setup_docker_cn.sh`（macOS/Linux）或 `setup_docker_cn.ps1`（Windows）配置 `registry-mirrors` |
| 单个镜像站缺某个特定 tag | 用 `pull_with_fallback.sh <ref>` 或 `pull_with_fallback.ps1 <ref>` 自动回退并回打标准名 |
| `ghcr.io` / `quay.io` / `gcr.io` / `mcr.microsoft.com` | 不受 daemon `registry-mirrors` 管辖；设置 `NONHUB_PREFIXES` 或用按需代理拉取 |
| 大镜像分片中途断流 | `daemon.json` 将 `max-concurrent-downloads` 调至 `3` 后重试 |

### B3 `exec format error` / `/usr/bin/env: 'bash\r': No such file or directory`

| 精确症状 | 根因 | 处置 |
| :--- | :--- | :--- |
| `exec format error`（架构不匹配） | Apple Silicon (arm64) Mac 与 amd64 镜像混拉，或镜像站返回了错误架构 manifest | `pull_with_fallback.sh <ref> --platform linux/amd64`（或 `linux/arm64`），并用 `docker image inspect --format '{{.Os}}/{{.Architecture}}'` 核验 |
| `'bash\r': No such file or directory` 或 `sh\r` | **Windows Git `core.autocrlf=true` 把 `.sh` / `mvnw` 转成了 CRLF**，拷入 Linux 容器后内核把 `\r` 当成解释器名的一部分 | 仓库加 `.gitattributes`（`*.sh text eol=lf`），或在 Dockerfile 中 `sed -i 's/\r$//' script.sh` |
| Windows Git Bash 下 `docker run ... /dev/null` 报路径错误 | MSYS2 自动把 `/dev/null` 改写成 `C:/Program Files/Git/dev/null` | 命令前加 `MSYS_NO_PATHCONV=1`（本工具箱所有 `.sh` 已内置） |

### B4 `x509: certificate ...`

| 精确报错 | 根因 | 处置 |
| :--- | :--- | :--- |
| `certificate has expired or is not yet valid` | 宿主或虚拟机时钟漂移（常见于笔记本休眠唤醒后的 WSL2 / Docker Desktop VM） | Linux: `timedatectl` / `chronyd`；macOS: `sudo sntp -sS time.apple.com`；Windows: 管理员运行 `w32tm /resync`；WSL2 休眠漂移: `sudo hwclock -s` 或 `wsl --shutdown` |
| `unable to get local issuer certificate` | 精简镜像缺 CA 证书，或公司/中转网关缺少中间证书链 | 镜像内装 `ca-certificates`（`apt-cn.sh` 已自动处理）；网关侧补齐 fullchain |
| `certificate signed by unknown authority` | 内部私有 Registry 自签证书 | 将根证书放入 `/etc/docker/certs.d/<host>/ca.crt`（Docker Desktop 在 Settings → Docker Engine / 系统钥匙串信任） |

### B5 小请求正常、大响应卡死

| 根因 | 处置 |
| :--- | :--- |
| VPN / WireGuard / Overlay 网络导致实际有效 MTU 小于 1500 | `daemon.json` 设 `"mtu": 1400`，或 compose network 加 `driver_opts: com.docker.network.driver.mtu: "1400"` |

查看接口 MTU：
- Linux: `ip link show docker0`
- macOS: `ifconfig en0 | grep mtu`
- Windows PowerShell: `Get-NetIPInterface -AddressFamily IPv4`

### B6 只有 IPv6 存在 AAAA 记录时先卡 10s 再回退

| 根因 | 处置 |
| :--- | :--- |
| 容器/WSL2/云主机拿到 AAAA 记录但无有效 IPv6 出口路由 | compose 注入 `sysctls: net.ipv6.conf.all.disable_ipv6=1`（`inject_cn_compose.py --disable-ipv6`），或 `curl -4` |

### B7 构建 20 分钟无输出（“卡住”但没报错）

| 根因 | 处置 |
| :--- | :--- |
| 巨大 build context（把几 GB 数据目录发给 daemon） | 配置 `.dockerignore`，或挂载卷构建 |
| `apt-get install` 等待交互输入（如 `tzdata`） | `DEBIAN_FRONTEND=noninteractive` + `-y` |
| `./mvnw` / `mvnw.cmd` 正在境外下载 Maven 本体 | 运行 `maven-cn.sh <repo>` 或 `pkg-cn.ps1 maven <repo>` 改写 wrapper `distributionUrl` |
| `./gradlew` / `gradlew.bat` 正在下载 Gradle 本体 | 将 `gradle-wrapper.properties` 的 `distributionUrl` 改为腾讯云 Gradle 镜像 |
| `npm ci` 在拉取 `node-gyp` 头文件或二进制包 | 先跑 `npm-cn.sh` / `pkg-cn.ps1 npm` 写入完整二进制镜像配置 |
| BuildKit 折叠了构建输出 | 加 `--progress=plain` 查看真实卡点 |

### B8 容器 `Up` 但首屏很慢 / healthcheck 一直 failing

- 排查是否启动期阻塞在更新检查/应用商店/遥测：参见 [app_offline_overrides.md](app_offline_overrides.md)。
- 检查 `HEALTHCHECK` 是否调用了精简镜像里不存在的 `curl`（改用 `wget -qO-`）。

### B9 Git / GitHub 与 LLM 网关

| 现象 | 处置 |
| :--- | :--- |
| `Failed to connect to github.com port 443` | `git-cn.sh gh-clone <url>` 或 `pkg-cn.ps1 git gh-clone <url>` |
| clone 卡在 `Downloading ... (LFS)` | 设 `GIT_LFS_SKIP_SMUDGE=1`（PowerShell: `$env:GIT_LFS_SKIP_SMUDGE="1"`）跳过大文件自动拉取 |
| Windows `python3` 弹出 Microsoft Store 或退出码 9009 | Windows 应用执行别名桩导致；改用 `python` / `py -3`（或在“管理应用执行别名”中关掉 `python3.exe` 快捷方式） |
| 本地回环请求返回 `502 Bad Gateway` | 代理环境变量污染了回环地址；确保 `NO_PROXY="127.0.0.1,localhost,::1,host.docker.internal"` |
