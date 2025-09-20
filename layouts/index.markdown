## 最新内容

{{- range .Site.RegularPages.ByDate.Reverse }}
{{- if not .Draft }}

### [{{ .Title }}]({{ .Permalink }})

**发布时间：** {{ .Date.Format "2006-01-02" }}

{{ .Summary }}

[阅读全文]({{ .Permalink }})

---
{{- end }}
{{- end }}

## 订阅方式

- **RSS订阅：** [{{ .Site.BaseURL }}index.xml]({{ .Site.BaseURL }}index.xml)
- **Telegram频道：** [t.me/ai_daily_briefing](https://t.me/ai_daily_briefing)
- **GitHub项目：** [GitHub仓库](https://github.com/YYvanYang/AIHeadline.news)

---

*本站由 [Hugo](https://gohugo.io/) 驱动，使用 [Hextra](https://github.com/imfing/hextra) 主题*
