---
name: cn-network
description: "中国大陆网络环境跨平台适配与排障（macOS / Linux / Windows PowerShell·CMD·WSL2·Git Bash）：依赖换源（brew/apt/apk/maven/gradle/npm/pip/composer/gem/go/cargo/conda）、Docker registry/BuildKit 加速、GitHub 下载代理、按需 mihomo 代理、8 层网络体检。Use when any download, install, docker pull/build, brew/pip/npm/mvn/cargo/go command, or git clone stalls, times out, or fails with DNS/TLS/EOF errors on a mainland-China macOS, Linux, or Windows host."
---

# cn-network — 中国大陆网络环境跨平台适配（macOS · Linux · Windows）

可移植的国内网络工具箱：优先把镜像站**幂等写入持久配置**（备份原文件为 `*.cn-bak`、托管块可重复执行），而不是给每条命令临时拼参数；代理仅作为单条无镜像境外命令的最后兜底。全面兼容 **macOS**、**Linux**、**Windows 原生 PowerShell / CMD** 以及 **WSL2 / Git Bash**。

## 什么时候用

出现以下任一症状即可使用本 skill：

- `brew / pip / uv / npm / pnpm / yarn / mvn / gradle / composer / bundle / go / cargo / conda / apt / apk` 安装卡住、超时、`Could not resolve dependencies`
- `docker pull` / `docker compose up` 拉镜像报 `EOF`、`TLS handshake timeout`、`manifest unknown`、`toomanyrequests`
- `docker build` 里 `RUN apt-get update` 报 `Temporary failure in name resolution`，但宿主机 `docker pull` 正常（**BuildKit 使用独立 DNS 解析器**）
- Windows 下构建 Linux 镜像报 `/usr/bin/env: 'bash\r': No such file or directory`（CRLF 换行符污染）或 WSL2 改 `/etc/docker/daemon.json` 不生效
- Apple Silicon (M 系列) Mac 与 `linux/amd64` 镜像混用报 `exec format error`
- `git clone` / GitHub release / raw 文件 / submodule 超时，或 HuggingFace 模型下载超时
- 容器 `Up` 但 `healthcheck` 持续失败、首屏转圈几十秒（启动期阻塞在应用商店/更新检查/遥测/境外 CDN）
- 需要给 Agent / CI 注入“中国大陆网络约束”提示文本

## 五条铁律

1. **先换源，再装包；代理是最后手段。**
2. **优先改持久配置**（`.npmrc`、`settings.xml`、`pip.conf`/`pip.ini`、`daemon.json`），一次生效、幂等可重入。
3. **固定 8 层排查顺序**：宿主 DNS → 宿主出网 → Docker daemon → 镜像拉取 → BuildKit → 容器 DNS → 容器出网 → 应用外呼。任一层 `FAIL` 先修该层，不往下猜。
4. 只有某条境外命令确实没有国内镜像时，才用 `mihomo_ctl.sh run <cmd>`（Windows 用 `mihomo_ctl.ps1 run <cmd>`）临时包裹单条命令；`NO_PROXY` 必须含 `127.0.0.1,localhost,::1,host.docker.internal`。
5. **绝不**直接覆盖 `daemon.json`（会丢失 `runtimes`/`data-root`/`builder`），**绝不**用 `echo "$PASS" | sudo -S tee`（免密缓存时密码会写进 JSON 首行导致 `dockerd` 无法启动）。

---

## 快速开始

### macOS / Linux / WSL2 / Git Bash

```bash
SKILL=~/.config/opencode/skills/cn-network

# 1) Docker 镜像站 + DNS 安全合并（自动识别 Linux /etc/docker/daemon.json、macOS ~/.docker/daemon.json、WSL2 Docker Desktop）
bash "$SKILL/scripts/setup_docker_cn.sh" --dry-run      # 先预览合并结果
sudo bash "$SKILL/scripts/setup_docker_cn.sh"           # Linux rootful 需要 sudo
bash "$SKILL/scripts/setup_docker_cn.sh" --restart      # macOS Docker Desktop / OrbStack / Colima 无需 sudo

# 2) 8 层网络体检
bash "$SKILL/scripts/diagnostics/net_diagnose.sh"

# 3) 常用包管理器一键换源（幂等，自动备份 *.cn-bak）
bash "$SKILL/scripts/pkg/brew-cn.sh"                    # macOS / Linuxbrew
bash "$SKILL/scripts/pkg/pip-cn.sh"
bash "$SKILL/scripts/pkg/npm-cn.sh"
bash "$SKILL/scripts/pkg/maven-cn.sh" /path/to/project
```

### Windows（PowerShell 5.1+ / PowerShell 7 / CMD）

```powershell
$SKILL = "$HOME\.config\opencode\skills\cn-network"

# 1) Docker Desktop / Windows Server daemon.json 安全合并（零 Python 依赖）
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\setup_docker_cn.ps1" --dry-run
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\setup_docker_cn.ps1" --restart

# 2) 8 层网络体检
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\diagnostics\net_diagnose.ps1"

# 3) 语言生态换源（pip / npm / maven / gradle / cargo / conda / go / composer / gem / git / all）
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\pkg\pkg-cn.ps1" pip
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\pkg\pkg-cn.ps1" npm --project
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\pkg\pkg-cn.ps1" maven C:\path\to\project
```

> 在传统 `cmd.exe` 中可直接执行上述 `powershell -NoProfile -ExecutionPolicy Bypass -File ...` 命令；所有 `.ps1` 脚本均同时兼容 `--dry-run` 与 `-DryRun` 风格参数。

---

## 跨平台路径与关键差异速查

| 配置项 | Linux | macOS | Windows（含 WSL2 Docker Desktop） |
| :--- | :--- | :--- | :--- |
| Docker `daemon.json` | `/etc/docker/daemon.json`（rootless: `~/.config/docker/daemon.json`） | `~/.docker/daemon.json`（OrbStack: `~/.orbstack/config/docker.json`） | `%USERPROFILE%\.docker\daemon.json`（Server: `%ProgramData%\docker\config\daemon.json`；WSL2 内对应 `/mnt/c/Users/<User>/.docker/daemon.json`） |
| BuildKit 配置 | `/etc/buildkit/buildkitd.toml` 或 `buildx --config` | `docker buildx create --use --config scripts/docker/buildkitd.toml` | `docker buildx create --use --config scripts\docker\buildkitd.toml` |
| Python `pip` | `~/.config/pip/pip.conf` | `~/.config/pip/pip.conf` | `%APPDATA%\pip\pip.ini` |
| Node `npm/pnpm` | `~/.npmrc` | `~/.npmrc` | `%USERPROFILE%\.npmrc` |
| Maven / Gradle | `~/.m2/settings.xml`、`~/.gradle/init.d/cn.gradle` | 同 Linux | `%USERPROFILE%\.m2\settings.xml`、`%USERPROFILE%\.gradle\init.d\cn.gradle` |
| Cargo / Conda / Go | `~/.cargo/config.toml`、`~/.condarc`、`~/.config/go/env` | `~/.cargo/config.toml`、`~/.condarc`、`~/Library/Application Support/go/env` | `%USERPROFILE%\.cargo\config.toml`、`%USERPROFILE%\.condarc`、`%APPDATA%\go\env` |

---

## 脚本索引

| 任务 | macOS / Linux / WSL2 / Git Bash | Windows PowerShell / CMD |
| :--- | :--- | :--- |
| Docker daemon 镜像站 + DNS | `scripts/setup_docker_cn.sh` | `scripts/setup_docker_cn.ps1` |
| Dockerfile / compose 静态体检 | `python3 scripts/mirror_lint.py Dockerfile --json` | `python scripts\mirror_lint.py Dockerfile --json` |
| 镜像多站回退拉取 + 架构校验 + 回打 tag | `scripts/registry/pull_with_fallback.sh` | `scripts/registry/pull_with_fallback.ps1` |
| 预热常用基础镜像 | `scripts/registry/prepull_base_images.sh` | `scripts/registry/prepull_base_images.ps1` |
| 已拉镜像回打标准名（纯本地零网络） | `scripts/registry/retag_mirrored_images.sh` | `scripts/registry/retag_mirrored_images.ps1` |
| 8 层分层网络体检 | `scripts/diagnostics/net_diagnose.sh` | `scripts/diagnostics/net_diagnose.ps1` |
| 按需 mihomo 代理（默认停止） | `scripts/mihomo_ctl.sh run <cmd>` | `scripts/mihomo_ctl.ps1 run <cmd>` |
| Homebrew（macOS / Linuxbrew） | `scripts/pkg/brew-cn.sh` | — |
| 容器内 APT / APK 换源 | `scripts/pkg/apt-cn.sh`、`apk-cn.sh` | 在 Dockerfile `RUN` 内调用同左（保持 `eol=lf`） |
| Maven / Gradle / npm / pip / composer / gem / go / git | `scripts/pkg/{maven,npm,pip,composer,gem,go,git}-cn.sh` | `scripts/pkg/pkg-cn.ps1 <tool>` |
| Cargo / Conda 模板 | `scripts/pkg/cargo-cn.toml`、`conda-cn.condarc` | `pkg-cn.ps1 cargo` / `pkg-cn.ps1 conda` 自动安装 |
| compose 注入 DNS / NO_PROXY / TZ / 禁 IPv6 | `python3 scripts/container/inject_cn_compose.py compose.yml -i` | `python scripts\container\inject_cn_compose.py compose.yml -i` |
| 构建期基础层 / Maven / Agent 约束文本 | `assets/Dockerfile.cn-base`、`assets/maven-settings.xml`、`assets/env_guidance.txt` | 同左 |

---

## 常用配方

### 1. Dockerfile：换源必须放在装包与 `COPY . .` 之前

```dockerfile
FROM <base>
COPY scripts/pkg/apt-cn.sh /tmp/apt-cn.sh
RUN sed -i 's/\r$//' /tmp/apt-cn.sh && bash /tmp/apt-cn.sh   # 兼顾 Windows 宿主防 CRLF
RUN apt-get install -y --no-install-recommends ca-certificates curl git
ENV PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/ \
    NPM_CONFIG_REGISTRY=https://registry.npmmirror.com \
    GOPROXY=https://goproxy.cn,direct
# ...最后才 COPY 业务源码 + install/build（最易变的层放最后，最大化命中缓存）
```

### 2. 拉镜像与跨架构校验

```bash
# macOS / Linux / Git Bash
bash "$SKILL/scripts/registry/pull_with_fallback.sh" redis:6-alpine
bash "$SKILL/scripts/registry/pull_with_fallback.sh" ghcr.io/org/img:v1 --platform linux/amd64
```

```powershell
# Windows PowerShell
& "$SKILL\scripts\registry\pull_with_fallback.ps1" redis:6-alpine
```

非 Docker Hub 仓库（`ghcr.io`/`quay.io`/`gcr.io`/`mcr.microsoft.com`）不受 `daemon.json` 的 `registry-mirrors` 影响，需搭配 `NONHUB_PREFIXES` 或按需代理。

### 3. 容器运行期外呼收敛

```bash
docker compose -p <project> -f docker-compose.yml \
  -f "$SKILL/scripts/container/compose.cn.override.yml" up -d
```

只调整网络（`dns` / `extra_hosts` / `NO_PROXY` / 禁 IPv6 / `TZ`），**不改动应用业务逻辑与安全配置**。常见开源软件的离线开关见 [references/app_offline_overrides.md](references/app_offline_overrides.md)。

### 4. 典型误诊速查

详细手册见 [references/troubleshooting.md](references/troubleshooting.md)，镜像全表见 [references/mirrors.md](references/mirrors.md)。

| 症状 | 真因与处置 |
| :--- | :--- |
| `docker pull` 正常，`docker build` 里 `apt-get` 解析失败 | BuildKit 不读 Linux `daemon.json` 的 `dns`；配 `buildkitd.toml` 或 `docker buildx create --use --config scripts/docker/buildkitd.toml` |
| WSL2 改了 `/etc/docker/daemon.json` 仍拉不动 | Docker Desktop 读取的是 Windows 侧 `%USERPROFILE%\.docker\daemon.json`；直接运行 `setup_docker_cn.sh` 或 `.ps1` |
| Windows 构建容器报 `'bash\r': No such file or directory` | Git `autocrlf` 把脚本转成了 CRLF；保留 `.gitattributes`（`*.sh text eol=lf`）或 `sed -i 's/\r$//'` |
| Apple Silicon Mac 容器秒退报 `exec format error` | 拉到了 `amd64`/`arm64` 不匹配的镜像；加 `--platform` 重新拉取 |
| 小请求正常，大响应卡死 | VPN/Overlay MTU 问题：`daemon.json` 设 `"mtu": 1400` |
| `x509: certificate has expired` | 休眠唤醒后时钟漂移：macOS `sntp` / Linux `chronyd` / Windows `w32tm /resync` / WSL2 `wsl --shutdown` |

## 维护约定

- 默认 Docker Hub 镜像回退顺序在 `scripts/setup_docker_cn.sh`、`scripts/setup_docker_cn.ps1`、`scripts/mirror_lint.py`、`assets/env_guidance.txt` 四处保持严格同步。
- 所有脚本坚持幂等修改与备份优先（首次修改前生成 `*.cn-bak`），不污染全局系统代理。
