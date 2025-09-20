{{- if and .Title (not .Params.hideTitle) }}
# {{ .Title }}

{{- end }}

{{- if .Content }}
{{ .Content }}

---
{{- end }}

## 文章列表

{{- range .Pages }}
{{- if not .Draft }}

### [{{ .Title }}]({{ .Permalink }})

**发布时间：** {{ .Date.Format "2006-01-02" }}
{{- if .Summary }}

{{ .Summary }}
{{- end }}

[阅读全文]({{ .Permalink }})

---
{{- end }}
{{- end }}

**返回首页：** [{{ .Site.Title }}]({{ .Site.BaseURL }})