# 🛠️ AI News Hugo 部署指南 - Cloudflare Workers + GitHub Pages

> 目标：**aiheadline.news**
>
> * 生产：Cloudflare Worker (Assets 模式)
> * 备份：GitHub Pages
> * 统计：GA4 累计访问量 + 实时在线人数（/stats API，使用自签名 JWT）
> * 单一 GitHub Actions 工作流

---

## 架构总览

本项目采用双重部署架构，通过单一 GitHub Actions 工作流实现两个独立的部署目标：

- **主要生产环境**：Cloudflare Workers + Assets (aiheadline.news)
- **备份镜像环境**：GitHub Pages (yyvanyang.github.io/AIHeadline.news)

### 部署流程图

```mermaid
graph TB
  A[触发器: git push / cron / manual] --> B[Job 1: build]
    B --> B1[同步内容<br>ai-briefing-archive → content/]
  B1 --> B2[Hugo 构建<br>content/ → public/]
  B2 --> B3[上传 Pages Artifact<br>public/ → GitHub]
  
  B3 --> C[Job 2: deploy-gh-pages]
  C --> C1[(GitHub Pages<br>备份镜像)]
  
  B --> D[Job 3: deploy-cf-worker]
  D --> D1[独立同步内容]
  D1 --> D2[独立 Hugo 构建<br>→ public/]
  D2 --> D3[Wrangler 部署<br>public/ → CF Workers]
  D3 --> D4[(Cloudflare Workers<br>主要生产环境)]
  
  style B fill:#e1f5fe
  style C fill:#f3e5f5
  style D fill:#fff3e0
  style C1 fill:#f3e5f5
  style D4 fill:#fff3e0
```

### 独立构建策略

两个部署目标采用完全独立的构建过程：

1. **GitHub Pages 构建**：在 `build` 作业中完成，构建产物通过 GitHub Pages artifact 机制传递
2. **Cloudflare Workers 构建**：在 `deploy-cf-worker` 作业中独立执行完整的内容同步和构建流程

这种设计确保：
- 两个部署环境完全隔离，互不影响
- 每个环境都有完整的构建上下文
- 部署失败不会相互影响
- 可以独立调试和优化每个部署流程

---

## 1. Cloudflare 配置

### 1.1 创建 Worker
1. 登录 [Cloudflare Dashboard][cf-dashboard]
2. 进入 **Workers & Pages**
3. 点击 **Create** → **Workers** → **Create Worker**
4. 命名为 `aiheadline-news`
5. 点击 **Deploy**（空脚本即可）

### 1.2 配置域名路由
1. 在 Worker 页面，点击 **Settings** → **Triggers**
2. 点击 **Add Custom Domain**
3. 输入 `aiheadline.news`
4. 点击 **Add Custom Domain**

### 1.3 创建 API Token
1. 点击右上角头像 → **My Profile**
2. 选择 **API Tokens** 标签
3. 点击 **Create Token**
4. 使用 **Custom token** 模板
5. 设置权限：
   - **Account** → Workers Scripts: Edit
   - **Zone** → 选择你的域名 → Zone: Read
6. 点击 **Continue to summary** → **Create Token**
7. 复制生成的 Token

### 1.4 获取 Account ID
1. 返回 Cloudflare Dashboard 首页
2. 右侧边栏可以看到 **Account ID**
3. 复制这个 ID

---

## 2. 代码结构

```
├── _worker.ts                           # Worker 脚本（包含 JWT 自签名实现）
├── wrangler.jsonc                       # Assets 绑定配置（推荐格式）
├── hugo.toml                            # GA4 Measurement ID, baseURL
├── go.mod                               # Hugo 模块依赖
├── go.sum                               # Go 模块校验和
├── package.json                         # npm 依赖和脚本
├── package-lock.json                    # npm 锁定文件
├── tsconfig.json                        # TypeScript 配置
├── .dev.vars.example                    # 本地环境变量示例
├── .editorconfig                        # 编辑器配置
├── .prettierrc                          # Prettier 格式化配置
├── .gitignore                           # Git 忽略文件
├── README.md                            # 项目说明文档
├── LICENSE                              # 许可证文件
├── archetypes/
│   └── default.md                       # Hugo 内容模板
├── layouts/
│   ├── index.html                       # 首页布局：构建时抓取最新日报正文
│   ├── _partials/
│   │   ├── custom/
│   │   │   └── footer.html              # 包含统计显示的自定义页脚
│   │   ├── daily-header.html            # 日报标题渲染
│   │   ├── month-index.html             # 月度归档列表渲染
│   │   └── title-controller.html        # 标题控制器
│   ├── docs/
│   │   ├── list.html                    # 文档列表页面模板
│   │   └── single.html                  # 文档单页模板
│   ├── index.rss.xml                    # 首页 RSS 模板
│   └── section.rss.xml                  # 分类 RSS 模板
├── assets/
│   └── css/
│       └── custom.css                   # 自定义样式（Hugo 处理）
├── static/
│   ├── images/
│   │   ├── light-logo-350x100.webp      # 浅色主题 Logo
│   │   ├── light-logo-350x100.png       # 浅色主题 Logo (PNG)
│   │   ├── dark-logo-350x100.webp       # 深色主题 Logo
│   │   ├── dark-logo-350x100.png        # 深色主题 Logo (PNG)
│   │   ├── logo.svg                     # SVG Logo
│   │   ├── logo-dark.svg                # 深色 SVG Logo
│   │   └── logo-original.png            # 原始 Logo
│   ├── favicon.ico                      # 网站图标
│   ├── favicon.svg                      # SVG 图标
│   └── apple-touch-icon.png             # Apple 触摸图标
├── logos/                               # Logo 源文件目录
│   ├── dark-logo.png                    # 深色 Logo 源文件
│   ├── light-logo.png                   # 浅色 Logo 源文件
│   ├── resize_logos.sh                  # Logo 调整脚本
│   └── out/                             # Logo 输出目录
├── docs/
│   └── deployment-guide.md              # 部署指南文档
├── .github/
│   ├── workflows/
│   │   └── deploy.yml                   # CI/CD 工作流
│   ├── scripts/
│   │   ├── sync-news.sh                 # 内容同步脚本（写入 front matter 元数据）
│   │   ├── test-sync.sh                 # 测试同步脚本
│   │   ├── dev.sh                       # 开发脚本
│   │   └── post-deploy-setup.sh         # 部署后设置脚本
│   └── dependabot.yml                   # Dependabot 配置
├── content/                             # Markdown 内容（自动生成，请勿手动编辑）
└── public/                              # Hugo 构建输出（自动生成）
```

> 首页与月度归档页面不再依赖 `.github/templates/` 预渲染 HTML，`sync-news.sh` 仅写入 `_index.md` 元数据。
> `layouts/index.html` 会在构建时选出最新的日报正文直接填充首页，并展示最近几日的快速导航；
> `layouts/_partials/month-index.html` 则根据月份目录下的实际内容生成归档列表。

### 首页与归档渲染流程（重要）

1. `bash .github/scripts/sync-news.sh`
   - 仅生成 `content/_index.md` 及 `content/YYYY-MM/_index.md` front matter，不再写入任何 HTML 正文。
   - 每篇日报依旧以 `content/YYYY-MM/YYYY-MM-DD.md` 保存 Markdown 正文，首个 H1 将被降级为 H2，保持页面语义。
2. `layouts/index.html`
   - 构建时从 `.Site.RegularPages` 选出日期最新的日报，直接渲染正文至首页“今日摘要”。
   - 自动挂载来源标签、上一日跳转与月份归档链接，无需手工维护模板。
3. `layouts/docs/list.html`
   - 根据 `_index.md` 中的 `month` 元数据判定是否为月归档页面。
   - 若为归档页则调用 `layouts/_partials/month-index.html` 动态渲染本月所有日报卡片。

> **提示**：若未来新增其他导航区块，仅需修改对应 Hugo 模板即可，内容生成脚本保持只写 front matter 的轻量职责。

### 2.1 `wrangler.jsonc`

```jsonc
{
  "name": "aiheadline-news",
  "main": "_worker.ts",
  "compatibility_date": "2025-07-13",
  "assets": {
    "directory": "./public",
    "binding": "ASSETS",
    "html_handling": "auto-trailing-slash",
    "not_found_handling": "404-page"
  },
  "observability": {
    "enabled": true,
    "head_sampling_rate": 1.0
  },
  "vars": {
    "GA4_PROPERTY_ID": "496539516",      // GA4 属性 ID（不需要在 Dashboard 中配置）
    "GA_START_DATE": "2025-07-12"        // 统计开始日期（站点上线日）
  }
}
```

**重要说明**：
- 使用 `wrangler.jsonc` 格式（Cloudflare 推荐）
- 项目采用 Web 标准 API 设计，无需 `nodejs_compat` 兼容性标志
- Worker 使用 WebCrypto API 自签名 JWT，无需外部 SDK（参考 [WebCrypto API 文档][cf-webcrypto]）
- 基于 Web 标准实现，bundle 更轻量，性能更优

### 2.2 `hugo.toml` 关键配置

```toml
# AI每日简报 - Hugo 站点配置
baseURL = "https://aiheadline.news/"
title = "AI每日简报 - 您的人工智能情报站"
languageCode = "zh-cn"
enableRobotsTXT = true
enableGitInfo = false
enableEmoji = true
hasCJKLanguage = true

# Hugo 模块配置
[module]
[[module.imports]]
path = "github.com/imfing/hextra"

# 站点参数
[params]
description = "每天 3 分钟，速览全球 AI 关键信息。自动聚合公开权威源，事件聚类 + LLM 摘要，原文一键直达；支持网站、RSS 与 Telegram 订阅。"

# 导航栏配置
[params.navbar]
displayTitle = false
displayLogo = true

[params.navbar.logo]
path = "images/light-logo-350x100.webp"
dark = "images/dark-logo-350x100.webp"
width = 175
height = 50

# 页脚配置
[params.footer]
enable = true
displayCopyright = false
displayPoweredBy = false

# Google Analytics 配置
[services.googleAnalytics]
ID = "G-0DRRQBXZWN"
```

### 2.3 Worker 实现技术说明

**JWT 自签名流程**：
1. 使用 Service Account 的私钥通过 WebCrypto API 生成 JWT
2. 用 JWT 向 Google OAuth2 端点交换 Access Token
3. 使用 Access Token 调用 GA4 Data API

**相关技术文档**：
- [Service Account JWT 认证][google-jwt] - 了解 JWT 结构和认证流程
- [GA4 Data API REST][ga4-api] - API 端点和请求格式
- [Workers WebCrypto][cf-webcrypto] - RSA 签名实现

### 2.4 GitHub Actions 配置

**重要更新（2025年1月）**：
- 所有 GitHub Actions 必须升级到 v4 版本
- Hugo 版本使用 0.148.1
- Cloudflare Worker 部署采用独立构建方案

完整的 `Deploy AI News to Cloudflare & GitHub Pages` 工作流结构：

**工作流触发器**：
- 定时触发：每天 UTC 0点（北京时间8点）
- 手动触发：workflow_dispatch
- 推送触发：main 分支推送时

**三个作业结构及依赖关系**：

```yaml
jobs:
  # 1. 构建任务 - 为 GitHub Pages 准备构建产物
  build:
    runs-on: ubuntu-24.04
    env:
      HUGO_VERSION: 0.148.1
    steps:
      - name: Install Hugo CLI                 # 安装 Hugo 0.148.1
      - uses: actions/checkout@v4              # 检出网站代码
      - uses: actions/checkout@v4              # 检出私有新闻源仓库
      - name: Sync markdown files              # 同步内容到 content/
      - uses: actions/configure-pages@v5       # 配置 GitHub Pages
      - name: Build with Hugo                  # Hugo 构建到 public/
      - uses: actions/upload-pages-artifact@v3 # 上传构建产物

  # 2. GitHub Pages 部署 - 依赖 build 作业
  deploy-gh-pages:
    needs: build                               # 等待 build 作业完成
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/deploy-pages@v4          # 部署到 GitHub Pages

  # 3. Cloudflare Worker 部署 - 完全独立的构建流程
  deploy-cf-worker:
    runs-on: ubuntu-24.04
    if: github.ref == 'refs/heads/main'        # 仅在 main 分支执行
    env:
      HUGO_VERSION: 0.148.1
    steps:
      - uses: actions/checkout@v4              # 独立检出代码
      - name: Install Hugo CLI                 # 独立安装 Hugo
      - uses: actions/checkout@v4              # 独立检出新闻源
      - name: Sync markdown files              # 独立同步内容
      - name: Build with Hugo                  # 独立构建到 public/
      - uses: actions/setup-node@v4            # 设置 Node.js 环境
      - name: Install dependencies             # 安装 npm 依赖
      - uses: cloudflare/wrangler-action@v3    # 部署到 Cloudflare
        with:
          apiToken: ${{ secrets.CF_API_TOKEN }}
          accountId: ${{ secrets.CF_ACCOUNT_ID }}
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CF_API_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CF_ACCOUNT_ID }}
```

### 作业依赖关系说明

- **build** 作业：独立运行，为 GitHub Pages 准备构建产物
- **deploy-gh-pages** 作业：依赖 `build` 作业完成，使用其构建产物进行部署
- **deploy-cf-worker** 作业：完全独立运行，不依赖其他作业，执行完整的构建和部署流程

### 独立构建的优势

1. **隔离性**：两个部署环境完全隔离，一个失败不影响另一个
2. **并行性**：`build` 和 `deploy-cf-worker` 可以并行执行，提高效率
3. **可靠性**：每个环境都有完整的构建上下文，避免依赖问题
4. **调试性**：可以独立调试和优化每个部署流程

### 部署产物处理机制

#### GitHub Pages 部署产物流程

1. **构建阶段**：`build` 作业执行 Hugo 构建，生成 `public/` 目录
2. **产物上传**：使用 `actions/upload-pages-artifact@v3` 将 `public/` 目录打包上传
3. **产物传递**：GitHub Pages artifact 机制自动传递构建产物到部署作业
4. **部署阶段**：`deploy-gh-pages` 作业使用 `actions/deploy-pages@v4` 部署产物

#### Cloudflare Workers 部署产物流程

1. **独立构建**：`deploy-cf-worker` 作业独立执行完整的内容同步和 Hugo 构建
2. **本地产物**：在作业运行环境中直接生成 `public/` 目录
3. **Assets 绑定**：Wrangler 直接读取本地 `public/` 目录内容
4. **Worker 部署**：通过 Assets 绑定将 `public/` 目录内容部署到 Cloudflare Workers

#### `public/` 目录的双重用途

- **静态文件服务**：包含 Hugo 生成的所有静态文件（HTML、CSS、JS、图片等）
- **Assets 绑定源**：Cloudflare Workers 通过 Assets 绑定直接服务这些文件
- **Pages 部署源**：GitHub Pages 直接托管这些静态文件
- **统一构建输出**：两个部署目标使用相同的构建产物，确保一致性

这种设计确保两个部署环境提供完全相同的用户体验，同时保持部署流程的独立性和可靠性。

---

## 3. GitHub Secrets 配置

### 3.1 在 GitHub 配置 Secrets
1. 进入仓库：https://github.com/YYvanYang/AIHeadline.news
2. 点击 **Settings** → **Secrets and variables** → **Actions**
3. 点击 **New repository secret**
4. 依次添加以下 secrets：

| Secret                  | 说明                    | 获取方式 |
| ----------------------- | --------------------- | ------- |
| `CF_API_TOKEN`          | Cloudflare API Token  | 见 1.3 节 |
| `CF_ACCOUNT_ID`         | Cloudflare Account ID | 见 1.4 节 |
| `PERSONAL_ACCESS_TOKEN` | GitHub PAT（已有） | 用于访问私有 vault 仓库 |

### 3.2 Cloudflare Worker 环境变量

**重要说明**：
- `GA4_PROPERTY_ID` 已在 `wrangler.jsonc` 中配置为普通变量，无需在 Dashboard 中配置
- `GA4_SERVICE_KEY` 是敏感信息，必须通过 Dashboard 或 CLI 单独配置为加密变量

#### 配置 GA4_SERVICE_KEY Secret

**方法一：通过 Cloudflare Dashboard**
1. 进入 Worker 页面，**Settings** → **Variables**
2. 点击 **Add variable**
3. 配置以下内容：
   - 变量名：`GA4_SERVICE_KEY`
   - 类型：**Encrypt**（必须加密）
   - 值：完整的 Google Service Account JSON 内容

**方法二：通过 Wrangler CLI**
```bash
# 在项目根目录执行
wrangler secret put GA4_SERVICE_KEY
# 然后粘贴完整的 Service Account JSON
```

**Service Account JSON 格式示例**（详见 [Service Account 认证文档][google-jwt]）：
```json
{
  "type": "service_account",
  "project_id": "your-project-id",
  "private_key_id": "...",
  "private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n",
  "client_email": "...",
  "client_id": "...",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token",
  "auth_provider_x509_cert_url": "...",
  "client_x509_cert_url": "..."
}
```

**注意事项**：
- Secret 只需配置一次，后续部署会自动保留
- 每次通过 Actions 部署不会覆盖已配置的 secrets
- 本地开发使用 `.dev.vars` 文件（参考 `.dev.vars.example`）

---

## 4. 验收步骤

1. **本地测试**
   ```bash
   # 首次设置：复制并配置本地环境变量
   cp .dev.vars.example .dev.vars
   # 编辑 .dev.vars 文件，填入实际的 GA4_SERVICE_KEY
   
   # 同步最新内容（可选）
   bash .github/scripts/sync-news.sh
   
   # 构建和测试
   hugo --gc --minify
   npm run dev
   # 浏览 http://127.0.0.1:8787/
   ```

2. **推送验证**
   ```bash
   git push main
   ```
   Actions 完成后检查：
   - https://aiheadline.news 返回 Hugo 站点
   - 首页展示当日摘要，并同步显示 PV / 在线人数统计
   - GA4 Realtime 面板可看到活跃用户

---

## 5. 关键文档

| 内容 | 链接 |
| ---- | ---- |
| Workers Static Assets | [官方文档][cf-static-assets] |
| Assets Binding | [配置指南][cf-assets-binding] |
| GA4 Data API | [实时数据 API][ga4-realtime] |
| Service Account JWT | [JWT 认证文档][google-jwt] |
| Workers WebCrypto | [WebCrypto API][cf-webcrypto] |
| Hugo 文档 | [快速开始][hugo-quickstart] |

---

## 6. 手动触发部署

如需手动触发部署：

1. 进入仓库的 **Actions** 页面
2. 选择 `Deploy AI News to Cloudflare & GitHub Pages` 工作流
3. 点击 **Run workflow** 按钮
4. 选择 `main` 分支并运行

---

## 7. 故障排查

### 部署失败

1. **检查 Actions 日志**：
   - 查看具体错误信息
   - 特别注意 "Sync markdown files" 步骤

2. **常见错误**：
   - `set -euo pipefail` 相关错误：检查 `sync-news.sh` 脚本中的管道命令
   - 权限错误：确认 `PERSONAL_ACCESS_TOKEN` 配置正确且有访问私有 vault 仓库权限
   - Hugo 构建错误：检查模板语法和内容格式，确认 Hugo 版本为 0.148.1
   - Cloudflare 部署错误：
     - **"CLOUDFLARE_API_TOKEN environment variable" 错误**：检查 `CF_API_TOKEN` 和 `CF_ACCOUNT_ID` secrets 配置
     - **"Could not resolve" 错误**：检查网络连接和 Cloudflare API 端点
     - **"public directory does not exist" 错误**：确认独立构建方案正确执行 `hugo --gc --minify`
     - **"wrangler-action authentication" 错误**：确认 secrets 同时在 `with` 和 `env` 中配置

### Stats API 返回 500 错误

1. **检查错误日志**：
   - Cloudflare Dashboard → Workers → aiheadline-news → Logs
   - 查看具体错误信息（现在是结构化 JSON 日志）

2. **常见原因**：
   - **"Missing required environment variables"**：
     - 检查 `GA4_SERVICE_KEY` 是否已通过 Cloudflare Dashboard 或 `wrangler secret put` 配置
     - 确认 `wrangler.jsonc` 中有 `GA4_PROPERTY_ID` 和 `GA_START_DATE` 配置
   - **JWT 签名错误**：检查 Service Account JSON 格式，确保私钥格式正确（参考 [JWT 认证文档][google-jwt]）
   - **API 权限错误**：确认 Service Account 有 GA4 Data API 只读权限（参考 [GA4 Data API 文档][ga4-api]）
   - **WebCrypto API 错误**：检查 RSA 私钥导入和签名过程
   - **配额耗尽（429 错误）**：
     - 检查响应头 `X-GA-Quota-Warning`
     - 查看日志中的 `tokensRemaining` 字段
     - 系统会自动延长缓存时间以减少 API 调用

### 内容未更新

1. **验证源数据**：
   - 确认 ai-briefing-archive 仓库有新的 `.md` 文件（不处理 JSON/PDF）
   - 检查文件命名格式是否符合年月目录结构
   - 确认文件在正确的年月目录下且包含有效的 frontmatter

2. **查看同步日志**：
   - Actions 中查看 "Sync markdown files" 步骤输出
   - 确认 `sync-news.sh` 脚本找到并处理了预期的文件
   - 检查是否有文件被跳过或过滤

### 页面 404 错误

1. 确认双重部署都已完成（GitHub Pages 和 Cloudflare Workers）
2. 检查 URL 是否正确（注意大小写和路径格式）
3. 对于 Cloudflare Workers：
   - 检查自定义域名路由配置 (aiheadline.news)
   - 确认 Assets 绑定指向正确的 `public/` 目录
4. 对于 GitHub Pages：
   - 确认 `gh-pages` 分支存在且包含构建文件
   - 检查 Pages 设置中的源分支配置

### 本地开发问题

1. **环境变量配置**：
   ```bash
   # 复制环境变量模板
   cp .dev.vars.example .dev.vars
   # 编辑 .dev.vars，填入完整的 GA4_SERVICE_KEY JSON
   ```

2. **Hugo 服务器问题**：
   ```bash
   # 确认 Hugo 版本
   hugo version
   # 应显示 v0.148.1 或更高版本
   
   # 清理缓存重新构建
   hugo --gc --minify
   ```

3. **Wrangler 开发服务器问题**：
   ```bash
   # 检查 Node.js 版本（需要 18+）
   node --version
   
   # 重新安装依赖
   rm -rf node_modules package-lock.json
   npm install
   
   # 启动开发服务器
   npm run dev
   ```

### 调试技巧

1. **本地测试内容同步**：
   ```bash
   # 使用实际的同步脚本测试
   bash .github/scripts/sync-news.sh
   
   # 测试同步脚本（用于开发环境）
   bash .github/scripts/test-sync.sh
   ```

2. **本地预览和构建**：
   ```bash
   # Hugo 开发服务器（实时重载）
   hugo server --buildDrafts --buildFuture
   # 访问 http://localhost:1313 查看效果
   
   # 生产构建测试
   hugo --gc --minify
   # 检查 public/ 目录内容
   ```

3. **Worker 本地测试**：
   ```bash
   # 安装依赖（首次运行）
   npm ci
   
   # 启动 Wrangler 开发服务器
   npm run dev
   # 或者直接使用 wrangler 命令
   wrangler dev --assets ./public
   # 访问 http://127.0.0.1:8787 测试 Worker
   
   # 测试 Stats API 端点
   curl http://127.0.0.1:8787/stats
   ```

4. **环境变量调试**：
   ```bash
   # 检查本地环境变量
   wrangler dev --var GA4_PROPERTY_ID:496539516
   
   # 验证 Secret 配置（生产环境）
   wrangler secret list
   ```

5. **部署前验证**：
   ```bash
   # 验证 wrangler 配置
   wrangler deploy --dry-run
   
   # 检查构建输出
   ls -la public/
   
   # 验证 Hugo 配置
   hugo config
   ```

---

## 注意事项

1. **CSS 文件位置**：必须放在 `assets/css/` 目录，不是 `static/css/`
2. **页脚自定义**：使用 `layouts/_partials/custom/footer.html`，并在 `hugo.toml` 中禁用默认页脚
3. **内容管理**：永远不要手动编辑 `content/` 目录下的文件
4. **本地开发**：使用 `.github/scripts/sync-news.sh` 同步最新内容
5. **域名配置**：Cloudflare Workers 通过路由绑定域名，无需 CNAME 文件
6. **Wrangler 版本**：项目使用 Wrangler v4，确保 `package.json` 中版本正确
7. **Actions 版本**：2025 年 1 月 30 日后必须使用 v4 版本

---

## 更新日志

### 2025-07-18 代码质量优化
1. **Google Analytics API 优化**：
   - 修复 Realtime API 响应处理（只使用 rows，不使用 totals）
   - 添加配额监控（returnPropertyQuota: true）
   - 实现动态缓存策略（根据配额自动调整缓存时间）
   - 增强错误处理（QuotaExceededError 类）
   - 添加结构化日志和性能监控

2. **代码健壮性提升**：
   - 修复请求去重内存泄漏风险（添加时间戳和定期清理）
   - 添加请求超时控制（GA4 API 30秒，Token 交换 15秒）
   - 修复网络错误无限重试问题
   - 改进 GA4 响应验证（validateGA4Response）
   - 修复大型 ArrayBuffer 转换（分块处理避免栈溢出）

3. **TypeScript 最佳实践**：
   - 使用泛型替代 any（LogContext<T>）
   - 完善类型定义和类型守卫
   - 添加响应结构验证

### 2025-07-13 重要更新
1. **GitHub Actions 升级**：
   - 所有 actions 升级到 v4/v5 版本
   - Cloudflare Worker 部署改为独立构建方案
   - 修复了 artifact 解压和 public 目录问题

2. **Wrangler 配置**：
   - 从 `wrangler.toml` 迁移到 `wrangler.jsonc`
   - 移除 `nodejs_compat` 兼容性标志（使用 Web 标准 API）
   - 升级到 Wrangler v4.24.3

3. **Worker 实现优化**：
   - 使用 WebCrypto API 实现 JWT 自签名（[WebCrypto 文档][cf-webcrypto]）
   - 移除对 @google-analytics/data 包的依赖
   - 实现 Access Token 缓存机制
   - 改进 CORS 和错误处理
   - 完整实现参考：[Service Account JWT][google-jwt] 和 [GA4 API][ga4-api]

4. **认证修复**：
   - wrangler-action 需要同时在 `with` 和 `env` 中设置认证信息
   - 添加了详细的 Token 创建步骤

---

完整实施详情请参考项目中的各配置文件。

<!-- 链接引用定义 -->
[cf-dashboard]: https://dash.cloudflare.com/
[cf-webcrypto]: https://developers.cloudflare.com/workers/runtime-apis/web-crypto/
[cf-static-assets]: https://developers.cloudflare.com/workers/learning/how-the-cache-works/static-sites/
[cf-assets-binding]: https://developers.cloudflare.com/workers/configuration/variables/#assets
[google-jwt]: https://developers.google.com/identity/protocols/oauth2/service-account
[ga4-api]: https://developers.google.com/analytics/devguides/reporting/data/v1/rest
[ga4-realtime]: https://developers.google.com/analytics/devguides/reporting/data/v1/realtime-basics
[hugo-quickstart]: https://gohugo.io/getting-started/quick-start/
