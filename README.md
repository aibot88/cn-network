# cn-network

Cross-platform Mainland-China network adaptation skill (macOS · Linux · Windows).

中国大陆网络环境跨平台适配 skill：依赖换源、Docker registry / BuildKit 加速、GitHub 下载代理、按需 mihomo 代理、8 层网络体检与排障。原生支持 **macOS**、**Linux** 以及 **Windows（PowerShell / CMD / WSL2 / Git Bash）**。

## 安装

### macOS / Linux / WSL2 / Git Bash

```bash
# OpenCode
mkdir -p ~/.config/opencode/skills
cp -r cn-network ~/.config/opencode/skills/cn-network

# Claude Code
mkdir -p ~/.claude/skills
cp -r cn-network ~/.claude/skills/cn-network
```

### Windows（PowerShell）

```powershell
# OpenCode
New-Item -ItemType Directory -Force "$HOME\.config\opencode\skills" | Out-Null
Copy-Item -Recurse -Force .\cn-network "$HOME\.config\opencode\skills\cn-network"
`
# Claude Code
New-Item -ItemType Directory -Force "$HOME\.claude\skills" | Out-Null
Copy-Item -Recurse -Force .\cn-network "$HOME\.claude\skills\cn-network"
```

## 快速用法

对话中出现下载/构建超时、`docker pull`、`pip install`、`brew install`、`npm install` 等网络受阻场景即可自动触发，也可显式引用 [SKILL.md](SKILL.md)。

### macOS / Linux / WSL2 / Git Bash

```bash
SKILL=~/.config/opencode/skills/cn-network

bash "$SKILL/scripts/setup_docker_cn.sh" --dry-run       # 预览 daemon.json 合并结果（自动识别 macOS/Linux/WSL2）
bash "$SKILL/scripts/diagnostics/net_diagnose.sh"        # 8 层网络体检
bash "$SKILL/scripts/pkg/brew-cn.sh"                     # macOS / Linuxbrew 换源
bash "$SKILL/scripts/pkg/pip-cn.sh"                      # Python pip / uv / HF 换源
bash "$SKILL/scripts/pkg/npm-cn.sh"                      # Node npm / pnpm / 二进制站换源
```

### Windows（PowerShell / CMD）

```powershell
$SKILL = "$HOME\.config\opencode\skills\cn-network"

powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\setup_docker_cn.ps1" --dry-run
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\diagnostics\net_diagnose.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\pkg\pkg-cn.ps1" all
```

## 目录结构

| 路径 | 内容 |
| :--- | :--- |
| `SKILL.md` | 触发条件、五条铁律、跨平台快速开始、路径差异表、脚本索引与排障配方 |
| `scripts/setup_docker_cn.{sh,ps1}` | 安全合并 DNS 与 `registry-mirrors` 到 `daemon.json`（保留已有配置，支持 `--dry-run`） |
| `scripts/diagnostics/net_diagnose.{sh,ps1}` | 8 层体检：宿主 DNS → 出网 → Docker → BuildKit → 容器 → 时钟 → 包索引 → Git/LLM |
| `scripts/pkg/` | `brew`/`apt`/`apk`/`maven`/`gradle`/`npm`/`pip`/`composer`/`gem`/`go`/`git` 换源脚本、`cargo`/`conda` 模板与 Windows `pkg-cn.ps1` |
| `scripts/registry/` | 镜像多站回退拉取、架构校验、回打标准 tag、基础镜像预热（`.sh` + `.ps1`） |
| `scripts/mirror_lint.py` | Dockerfile / Compose 静态镜像源体检（支持 `--json`，跨平台识别 `daemon.json`） |
| `scripts/container/` | Compose 注入 `dns` / `NO_PROXY` / `TZ` / `host.docker.internal` / 禁 IPv6 |
| `scripts/docker/` | `daemon.json.example` 与跨平台 `buildkitd.toml` 模板 |
| `scripts/mihomo_ctl.{sh,ps1}` | 按需代理包裹器（默认停止，跑完即停） |
| `assets/` | `Dockerfile.cn-base` 基础层片段、`maven-settings.xml`、Agent 网络约束提示文本 `env_guidance.txt` |
| `references/` | 镜像源速查表、症状排障手册、开源应用离线/外联收敛开关 |
