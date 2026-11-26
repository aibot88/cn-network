# 应用运行期外联收敛清单（关闭“更新检查 / 应用商店 / 遥测 / 公共 CDN”）

在内网、离线或境外连接受限的环境中运行开源服务时，许多应用会在启动阶段、首屏渲染或后台定时任务中主动连接境外域名。常见表现：

- 容器显示 `Up`，但 `healthcheck` 持续失败（启动流程被外呼超时阻塞）
- 接口响应迟缓或首屏转圈 10–30s（浏览器或后端正在等待境外 CDN/商店接口超时）
- 日志频繁出现 `Connection timed out` / `Name or service not known` / `ETIMEDOUT` / `getaddrinfo`

> [!IMPORTANT]
> 处理原则：**只关闭非必要的更新检查、应用市场、遥测与公共 CDN，不修改应用本身的业务逻辑与安全配置**，确保行为与常规部署保持一致。

---

## 1. 通用兜底手段（优先使用，无需改业务代码）

| 手段 | 做法 | 适用场景 |
| :--- | :--- | :--- |
| 环境变量关闭遥测 | `*_TELEMETRY_ENDPOINT=""`、`SENTRY_DSN=""`、`DISABLE_TELEMETRY=1` | 大多数现代 Web / AI 应用 |
| 挂载本地 hosts | compose `extra_hosts` 将已知遥测/更新域名指向 `127.0.0.1` | 外呼域名固定且数量少 |
| 注入本地快速失败 DNS | compose 中给纯内网服务设置 `dns: [127.0.0.1]`（仅确认无需任何外网解析时） | 让外呼立即失败返回，避免每次挂起 30s |
| 关闭应用内更新检查 | 修改应用配置文件中的开关（见下文） | 各类 CMS / 协作平台 / DevOps 面板 |
| 旁路本地回环代理 | 确保 `NO_PROXY` 包含 `127.0.0.1,localhost,::1,host.docker.internal` | 防止容器间或宿主机回环请求误走代理 |

---

## 2. 逐应用离线/受限网络开关

### Nextcloud（PHP）
`config/config.php`（或 `config/autoconfig.php`）追加：
```php
$CONFIG = [
  'appstoreenabled'          => false,
  'appstoreurl'              => '',
  'has_internet_connection'  => false,
  'updatechecker'            => false,
  'check_for_working_webdav' => false,
  'check_data_directory_permissions' => false,
  'log_type'                 => 'file',
  // 关闭外部头像 / 远程服务探测
  'enable_avatars'           => false,
  'lost_password_link'       => 'disabled',
];
```
同时在后台禁用外部应用商店客户端插件（保留核心应用）。常见阻塞日志关键词：`appstore`、`updatechecker`、`gravatar`、`cloud.nextcloud.com`。

### WordPress（PHP）
`wp-config.php`：
```php
define('WP_HTTP_BLOCK_EXTERNAL', true);
define('WP_ACCESSIBLE_HOSTS', 'localhost,127.0.0.1');
define('AUTOMATIC_UPDATER_DISABLED', true);
define('WP_AUTO_UPDATE_CORE', false);
define('DISALLOW_FILE_MODS', true);
```
若插件仍强行外呼，可在测试环境 `functions.php` 中挂载 `add_filter('pre_http_request', '__return_false')` 直接短路外部 HTTP 请求。

### Jenkins
`$JENKINS_HOME/hudson.model.UpdateCenter.xml`：
```xml
<sites>
  <site>
    <id>default</id>
    <url>https://mirrors.tuna.tsinghua.edu.cn/jenkins/updates/update-center.json</url>
  </site>
</sites>
```
并在离线/内网环境中关闭 `Usage Statistics` 上报。

### GitLab（Ruby / Rails）
`/etc/gitlab/gitlab.rb`：
```ruby
gitlab_rails['usage_ping_enabled'] = false
gitlab_rails['version_check_enabled'] = false
gitlab_rails['gitlab_default_projects_features_container_registry'] = false
```
容器部署可通过 `GITLAB_OMNIBUS_CONFIG` 环境变量注入上述配置。

### Jira / Confluence / Bitbucket（Atlassian）
JVM 启动参数追加：`-Datlassian.plugins.disable.marketplace=true`、`-Dcom.atlassian.plugins.analytics.disabled=true`；Jira 另加 `-Djira.version.check.enabled=false`。

### SonarQube
`sonar.properties`：`sonar.updatecenter.activate=false`，并设置环境变量 `SONAR_TELEMETRY_ENDPOINT=""`。

### Elasticsearch / Kibana
`elasticsearch.yml`：`xpack.monitoring.collection.enabled: false`；
`kibana.yml`：`telemetry.enabled: false`、`xpack.monitoring.enabled: false`。

### Spring Boot / Java 应用（通用）
```properties
# 关闭指标外发上报
management.metrics.export.*.enabled=false
# 本地单机调试无需远程配置中心/注册中心时可显式关闭
spring.cloud.config.enabled=false
spring.cloud.discovery.enabled=false
```
若旧版 XML Schema 在线校验（`http://www.springframework.org/schema/...`）耗时过长，无外网时通常自动回退本地 classpath schema；必要时可配置 `-Djavax.xml.accessExternalSchema=all`。

### Node / 前端应用
```bash
DISABLE_OPENCOLLECTIVE=1
NEXT_TELEMETRY_DISABLED=1
NUXT_TELEMETRY_DISABLED=1
GATSBY_TELEMETRY_DISABLED=1
```
前端模板引用的 `fonts.googleapis.com` / `cdn.jsdelivr.net` / `unpkg.com` / `cdnjs.cloudflare.com` 在受限网络下会拖慢首屏渲染，可替换为本地静态资源或国内公共库。

### Python / AI 应用
```bash
SENTRY_DSN=""
DD_TRACE_ENABLED=false
OTEL_SDK_DISABLED=true
HF_HUB_OFFLINE=1           # 已预缓存模型时开启完全离线
TRANSFORMERS_OFFLINE=1
```

### 含在线商业许可证校验的组件
在内网或无外网环境中运行需联网校验证书的商业发行版时，若因无法连接外部授权服务器报超时，应归类为环境网络限制，避免与业务故障混淆。

---

## 3. 排障与变更核对清单

| 现象 | 建议处置 |
| :--- | :--- |
| 启动慢但最终健康、核心接口可用 | 关闭对应更新检查/遥测配置并在部署说明中记录 |
| 因外呼阻塞导致容器反复超时退出 | 从日志提取阻塞域名，用环境变量或 `extra_hosts` 收敛后重测 |
| 客户端脚本超时但容器内直连 `127.0.0.1` 秒回 | 检查宿主机是否开启了系统代理且漏配 `NO_PROXY` |

> [!CAUTION]
> 收敛外联时，仅修改遥测、更新检查与网络配置项，不要顺手放宽或注释应用原有安全配置。
