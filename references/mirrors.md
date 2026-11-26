# 镜像源与回退顺序（速查：macOS / Linux / Windows）

## 1. 镜像站/源对照表

| 生态 | 默认镜像 | 换源脚本 / 配置路径（macOS · Linux · Windows） |
| :--- | :--- | :--- |
| Docker Hub（daemon 层） | `docker.1ms.run` → `docker.1panel.live` → `docker.m.daocloud.io` | `setup_docker_cn.sh`（Linux `/etc/docker/daemon.json`、macOS `~/.docker/daemon.json`）；Windows `setup_docker_cn.ps1`（`%USERPROFILE%\.docker\daemon.json`） |
| 非 Hub registry（ghcr/quay/gcr/mcr） | 镜像站前缀，如 `ghcr.nju.edu.cn` | `NONHUB_PREFIXES=... pull_with_fallback.sh` / `pull_with_fallback.ps1` |
| macOS / Linux Homebrew | USTC（备选 `tuna` / `aliyun`） | `BREW_MIRROR=ustc brew-cn.sh`（写 `~/.zprofile` 或 `~/.bashrc`） |
| Debian/Ubuntu APT | `mirrors.aliyun.com`（备选 `mirrors.ustc.edu.cn`） | `APT_MIRROR=mirrors.ustc.edu.cn apt-cn.sh` |
| Alpine APK | `mirrors.aliyun.com` | `APK_MIRROR=... apk-cn.sh` |
| Java Maven | `https://maven.aliyun.com/repository/public` | `maven-cn.sh` / `pkg-cn.ps1 maven`（`~/.m2/settings.xml` 或 `%USERPROFILE%\.m2\settings.xml` + `mvnw` wrapper） |
| Gradle | 阿里云 Maven/Plugin + 腾讯云 wrapper | `~/.gradle/init.d/cn.gradle` 或 `%USERPROFILE%\.gradle\init.d\cn.gradle`（`pkg-cn.ps1 gradle`） |
| Python pip / uv / poetry | `https://mirrors.aliyun.com/pypi/simple/` | `pip-cn.sh`（`~/.config/pip/pip.conf`） / `pkg-cn.ps1 pip`（`%APPDATA%\pip\pip.ini`） |
| HuggingFace | `https://hf-mirror.com` | `HF_ENDPOINT` |
| Node npm / pnpm / yarn | `https://registry.npmmirror.com` + 二进制镜像 | `npm-cn.sh` / `pkg-cn.ps1 npm`（`~/.npmrc` 或 `%USERPROFILE%\.npmrc`） |
| PHP Composer | `https://mirrors.aliyun.com/composer/` | `composer-cn.sh` / `pkg-cn.ps1 composer` |
| RubyGems / Bundler | `https://mirrors.tuna.tsinghua.edu.cn/rubygems` | `gem-cn.sh` / `pkg-cn.ps1 gem` |
| Go modules | `https://goproxy.cn,direct` + `sum.golang.google.cn` | `go-cn.sh` / `pkg-cn.ps1 go`（`go env -w`） |
| Rust crates | `sparse+https://rsproxy.cn/index/` | `~/.cargo/config.toml` 或 `%USERPROFILE%\.cargo\config.toml`（`pkg-cn.ps1 cargo`） |
| Conda / Mamba | TUNA `anaconda/`（main/r/msys2/cloud） | `~/.condarc` 或 `%USERPROFILE%\.condarc`（`pkg-cn.ps1 conda`） |
| GitHub 文件 / release / clone | `https://ghfast.top/` 前缀 | `git-cn.sh` / `pkg-cn.ps1 git` |
| 容器内 DNS | `223.5.5.5`、`119.29.29.29` | `setup_docker_cn.*` / compose `dns:` |
| 境外单命令兜底 | 按需 mihomo，默认停止 | `mihomo_ctl.sh run <cmd>` / `mihomo_ctl.ps1 run <cmd>` |

## 2. 回退顺序的语义

`setup_docker_cn.sh` / `setup_docker_cn.ps1` 写入的 `registry-mirrors` 会按顺序尝试。注意三个盲区：

1. **单站缺 tag**：某个镜像站返回 `manifest unknown` 时，部分 Docker 版本不会自动继续尝试下一站 → 用 `pull_with_fallback.sh`（或 `.ps1`）显式轮询并回打标准 tag。
2. **非 Docker Hub registry 完全不受 `registry-mirrors` 影响**。
3. **架构不匹配不会在拉取时报错**：容器启动才报 `exec format error`（尤其 Apple Silicon M 系列 Mac 与 x86_64 镜像混用时）→ 拉取跨架构镜像务必指定 `--platform` 并用 `docker image inspect --format '{{.Os}}/{{.Architecture}}'` 核对。

## 3. 为什么“只加 registry”不够

- `npm config set registry` 只管元数据；真实预编译二进制来自各包独立域名。`npm-cn.sh` / `pkg-cn.ps1 npm` 直接写入 `.npmrc`（避开 npm v9+ CLI 对未知键报错）：
  `disturl` / `electron_mirror` / `electron_builder_binaries_mirror` / `sass_binary_site` / `sharp_binary_host` / `sharp_libvips_binary_host` / `puppeteer_download_host` / `playwright_download_host` / `chromedriver_cdnurl` 等。
- `maven-cn.sh` / `pkg-cn.ps1 maven` 除写入 `settings.xml` 外，还会把项目内 `.mvn/wrapper/maven-wrapper.properties` 的 `distributionUrl` 改到阿里云 —— `./mvnw` / `mvnw.cmd` 下载 Maven 本体是最常见的静默卡死点。

## 4. 修改默认值的同步位置

| 内容 | 文件 |
| :--- | :--- |
| daemon 镜像站顺序 + DNS | `scripts/setup_docker_cn.sh`、`scripts/setup_docker_cn.ps1` |
| lint 建议的前缀顺序 | `scripts/mirror_lint.py` |
| 注入给 agent 的文本 | `assets/env_guidance.txt` |
| 各生态默认源 | `scripts/pkg/*-cn.sh`、`scripts/pkg/pkg-cn.ps1` |

调整默认镜像站顺序时，务必同步以上位置，保持行为、静态检查与提示文本完全一致。
