# AIHeadline.news – AI 头条
[![CI](https://github.com/YYvanYang/AIHeadline.news/actions/workflows/deploy.yml/badge.svg)](https://github.com/YYvanYang/AIHeadline.news/actions/workflows/deploy.yml)
[![Production – Cloudflare Worker](https://img.shields.io/badge/Cloudflare%20Worker-Live-success?logo=cloudflare)](https://aiheadline.news)
[![Backup – GitHub Pages](https://img.shields.io/badge/GitHub%20Pages-Backup-blue?logo=github)](https://yyvanyang.github.io/AIHeadline.news/)

> **您的人工智能情报站**  
> Hugo × Hextra · 全球 Cloudflare 边缘加速

---

## ✨ 特性

| 类别 | 描述 |
|------|------|
| **内容自动化** | 每日同步仓库 [`ai-briefing-archive`](https://github.com/Joe-oss9527/ai-briefing-archive)，智能分类、按月归档 |
| **Hextra 主题** | 暗色/浅色、FlexSearch、站内链接卡片、RSS、PWA |
| **双环境发布** | Cloudflare Worker (Assets) 生产 • GitHub Pages 备份 |
| **实时统计** | GA4 Data API (JWT 自签名) 缓存到边缘：累计访问量 + 在线人数 |
| **独立部署架构** | Cloudflare Worker 独立构建，GitHub Pages 独立构建 |
| **可扩展** | Worker 可随时接入 KV、Durable Objects、Queues、D1、AI Bindings |

---

## 在线访问

| 环境 | 域名 |
|------|------|
| 生产 | **https://aiheadline.news** |
| 备份 | https://yyvanyang.github.io/AIHeadline.news/ |

---


## 本地开发

### 环境配置

Worker 本地开发需要配置 GA4 服务账号密钥：

1. 创建 `.dev.vars` 文件（已在 `.gitignore` 中）
2. 添加 GA4 服务账号 JSON（保持单行格式）：
   ```
   GA4_SERVICE_KEY={"type":"service_account","project_id":"...","private_key":"-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n","client_email":"...@....iam.gserviceaccount.com",...}
   ```

### 开发命令

```bash
# 同步最新内容
git submodule update --init --depth 1 source-news
bash .github/scripts/test-sync.sh

# 启动 Hugo 预览
hugo server

# 构建站点
hugo --gc --minify

# 启动 Worker 开发服务器（需先 npm ci）
npm run dev
```

---

## 快速部署

需要配置的核心 Secrets：
- `CF_API_TOKEN` & `CF_ACCOUNT_ID` - Cloudflare 部署
- `PERSONAL_ACCESS_TOKEN` - 访问 `ai-briefing-archive`（如需权限控制）
- `GA4_SERVICE_KEY` - Google Analytics 统计（Worker 环境变量）

📖 详细配置步骤、技术文档和故障排查请参考 [**部署指南**](docs/deployment-guide.md)

---

MIT License · Crafted by [@YYvanYang](https://github.com/YYvanYang)
