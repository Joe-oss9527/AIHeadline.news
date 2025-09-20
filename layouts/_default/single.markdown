# {{ .Title }}

**发布时间：** {{ .Date.Format "2006-01-02 15:04:05" }}
{{- if .Params.author }}
**作者：** {{ .Params.author }}
{{- end }}
{{- if .Params.categories }}
**分类：** {{ delimit .Params.categories ", " }}
{{- end }}
{{- if .Params.tags }}
**标签：** {{ delimit .Params.tags ", " }}
{{- end }}

---

{{ .Content }}

---

**原文链接：** {{ .Permalink }}

**网站首页：** [{{ .Site.Title }}]({{ .Site.BaseURL }})