#!/bin/bash
# AI每日简报内容同步脚本
# 
# 功能：从ai-news-vault仓库同步markdown文件并生成Hugo站点内容
# 作者：AI每日简报团队
# 版本：2.3 - 优化标题生成，避免重复

set -euo pipefail

# =============================================================================
# 配置常量
# =============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly SOURCE_DIR="${PROJECT_ROOT}/source-news"
readonly CONTENT_DIR="${PROJECT_ROOT}/content"
readonly TEMPLATE_DIR="${PROJECT_ROOT}/.github/templates"

# =============================================================================
# 工具函数
# =============================================================================

# 日志输出函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# 错误退出函数
die() {
    log "ERROR: $*"
    cleanup_temp_files
    exit 1
}

# 清理临时文件
cleanup_temp_files() {
    log "Cleaning up temporary files..."
    
    if [[ -d "$CONTENT_DIR" ]]; then
        find "$CONTENT_DIR" -name ".tmp_sync*" -type f -delete 2>/dev/null || true
        find "$CONTENT_DIR" -name ".*_tmp" -type f -delete 2>/dev/null || true
    fi
    
    log "Temporary files cleanup completed"
}

# 设置清理陷阱
trap cleanup_temp_files EXIT

# 验证日期格式 (YYYYMMDD)
validate_date() {
    local date_str="$1"
    [[ "$date_str" =~ ^[0-9]{8}$ ]] || return 1
    
    local year="${date_str:0:4}"
    local month="${date_str:4:2}"
    local day="${date_str:6:2}"
    
    # 基本范围检查 - 使用10#前缀强制十进制解析
    [[ "$year" -ge 2020 && "$year" -le 2030 ]] || return 1
    [[ $((10#$month)) -ge 1 && $((10#$month)) -le 12 ]] || return 1
    [[ $((10#$day)) -ge 1 && $((10#$day)) -le 31 ]] || return 1
    
    return 0
}

# 解析日期字符串
parse_date() {
    local date_str="$1"
    validate_date "$date_str" || die "Invalid date format: $date_str"
    
    echo "year=${date_str:0:4}"
    echo "month=${date_str:4:2}"
    echo "day=${date_str:6:2}"
}

# 计算权重（用于排序）
calculate_weight() {
    local year="$1"
    local month="$2"
    local day="${3:-1}"
    
    local year_num=$((10#$year))
    local month_num=$((10#$month))
    local day_num=$((10#$day))
    
    echo $((100000 - (year_num - 2000) * 1000 - month_num * 10 - day_num))
}

# 将 pipeline 标识转换成可读名称
pipeline_display_name() {
    local slug="$1"
    case "$slug" in
        ai-briefing-twitter-list)
            echo "AI 快讯 · Twitter"
            ;;
        ai-briefing-hackernews)
            echo "Hacker News 热点"
            ;;
        ai-briefing-reddit)
            echo "Reddit 精选"
            ;;
        ai-briefing-hn)
            echo "Hacker News 日报"
            ;;
        ai-briefing-all)
            echo "AI 简报"
            ;;
        *)
            # 默认将 slug 转换为可读形式
            echo "${slug//-/ }" | sed 's/\b./\u&/g'
            ;;
    esac
}

# 将 Markdown 标题级别整体下调一级，避免页面出现多个 H1
render_markdown_body() {
    local file="$1"
    python3 - "$file" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
lines = text.splitlines()
output = []
start_index = 0
if lines and lines[0].startswith('# '):
    start_index = 1
for line in lines[start_index:]:
    if line.startswith('# '):
        output.append('## ' + line[2:].lstrip())
    else:
        output.append(line)
sys.stdout.write('\n'.join(output))
PY
}

# 收集月份的所有日期
collect_month_dates() {
    local month_dir="$1"
    
    find "$month_dir" -mindepth 2 -maxdepth 2 -type f -name 'briefing_*.md' 2>/dev/null | \
        sed -n 's/.*briefing_\([0-9]\{8\}\)T[0-9]\{6\}Z\.md$/\1/p' | \
        sort -u | \
        while IFS= read -r date_str; do
            if validate_date "$date_str"; then
                echo "$date_str"
            else
                log "WARN: Skipping invalid date: $date_str"
            fi
        done
}

# 生成日报页面
generate_daily_page() {
    local month_dir="$1"
    local dest_dir="$2"
    local date_str="$3"

    eval "$(parse_date "$date_str")"
    local day_weight
    day_weight=$(calculate_weight "$year" "$month" "$day")

    local pipelines_list
    local files_list
    local times_list
    pipelines_list=()
    files_list=()
    times_list=()

    while IFS= read -r -d '' file; do
        local rel="${file#${month_dir}/}"
        local pipeline="${rel%%/*}"
        local filename="${file##*/}"

        if [[ "$filename" =~ ^briefing_([0-9]{8})T([0-9]{6})Z\.md$ ]]; then
            local file_date="${BASH_REMATCH[1]}"
            local time_part="${BASH_REMATCH[2]}"

            [[ "$file_date" == "$date_str" ]] || continue

            local iso_stamp="${file_date}T${time_part}Z"
            local idx=-1
            local i=0
            if [[ ${#pipelines_list[@]} -gt 0 ]]; then
                for existing in "${pipelines_list[@]}"; do
                    if [[ "$existing" == "$pipeline" ]]; then
                        idx=$i
                        break
                    fi
                    i=$((i + 1))
                done
            fi

            if [[ $idx -eq -1 ]]; then
                pipelines_list+=("$pipeline")
                files_list+=("$file")
                times_list+=("$iso_stamp")
            else
                if [[ "$iso_stamp" > "${times_list[$idx]}" ]]; then
                    files_list[$idx]="$file"
                    times_list[$idx]="$iso_stamp"
                fi
            fi
        else
            log "WARN: Unrecognized filename format: $filename"
        fi
    done < <(find "$month_dir" -mindepth 2 -maxdepth 2 -type f -name "briefing_${date_str}T*.md" -print0 2>/dev/null)

    if [[ ${#pipelines_list[@]} -eq 0 ]]; then
        log "WARN: No briefing files found for date $date_str"
        return 1
    fi

    local merged_file="${dest_dir}/${year}-${month}-${day}.md"
    : > "$merged_file"

    echo "---" >> "$merged_file"
    echo "title: "${year}年${month}月${day}日 AI 简报"" >> "$merged_file"
    echo "weight: $day_weight" >> "$merged_file"
    echo "date: ${year}-${month}-${day}" >> "$merged_file"
    echo "description: "AI每日简报 - ${year}年${month}月${day}日最新动态"" >> "$merged_file"

    local order=()
    local idx=0
    for pipeline in "${pipelines_list[@]}"; do
        order+=("${pipeline}:::${idx}")
        idx=$((idx + 1))
    done
    IFS=$'
' order=($(printf '%s
' "${order[@]}" | sort))

    if [[ ${#order[@]} -gt 0 ]]; then
        echo "sources:" >> "$merged_file"
        for entry in "${order[@]}"; do
            local pipeline="${entry%%:::*}"
            echo "  - $(pipeline_display_name "$pipeline")" >> "$merged_file"
        done

        echo "source_slugs:" >> "$merged_file"
        for entry in "${order[@]}"; do
            local pipeline="${entry%%:::*}"
            echo "  - $pipeline" >> "$merged_file"
        done
    else
        echo "sources: []" >> "$merged_file"
        echo "source_slugs: []" >> "$merged_file"
    fi

    echo "toc: true" >> "$merged_file"
    echo "---" >> "$merged_file"

    for entry in "${order[@]}"; do
        local pipeline="${entry%%:::*}"
        local idx="${entry##*:::}"
        local file="${files_list[$idx]}"
        local stamp="${times_list[$idx]}"
        local friendly
        friendly="$(pipeline_display_name "$pipeline")"

        local time_display=""
        if [[ "$stamp" =~ T([0-9]{2})([0-9]{2}) ]]; then
            time_display="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
        fi

        {
            echo ""
            if [[ -n "$time_display" ]]; then
                echo "## ${friendly} — ${time_display} 更新"
            else
                echo "## ${friendly}"
            fi
            echo ""
            render_markdown_body "$file"
            echo ""
        } >> "$merged_file"
    done

    log "Generated: $merged_file"
}

# 生成月份索引页面
generate_month_index() {
    local dest_dir="$1"
    local year="$2"
    local month="$3"
    local dates=("${@:4}")
    
    local weight
    weight=$(calculate_weight "$year" "$month")
    
    local template_file="${TEMPLATE_DIR}/month-index.md"
    [[ -f "$template_file" ]] || die "Template not found: $template_file"
    
    local temp_file="${dest_dir}/.month_index_tmp"
    local content_file="${dest_dir}/.content_tmp"
    
    # 生成内容列表
    : > "$content_file"
    for date_str in "${dates[@]}"; do
        eval "$(parse_date "$date_str")"
        cat >> "$content_file" << CONTENT_EOF
<div class="daily-article">
  <a href="${year}-${month}-${day}">${month}-${day} 日报</a>
</div>
CONTENT_EOF
    done
    
    # 替换模板占位符
    sed "s/{{YEAR}}/$year/g; s/{{MONTH}}/$month/g; s/{{WEIGHT}}/$weight/g" \
        "$template_file" > "$temp_file"
    
    # 插入内容
    sed "/{{CONTENT}}/r $content_file" "$temp_file" | \
        sed '/{{CONTENT}}/d' > "${dest_dir}/_index.md"
    
    # 清理临时文件
    rm -f "$temp_file" "$content_file"
    
    log "Generated month index: ${dest_dir}/_index.md"
}

# 生成首页
generate_home_page() {
    log "Starting home page generation..."
    
    local template_file="${TEMPLATE_DIR}/home-index.md"
    [[ -f "$template_file" ]] || die "Home template not found: $template_file"
    
    local cards_file="${CONTENT_DIR}/.cards_tmp"
    
    # 收集月份卡片
    : > "$cards_file"
    
    local month_count=0
    for month_dir in "${CONTENT_DIR}"/20*/; do
        [[ -d "$month_dir" ]] || continue
        [[ -f "${month_dir}/_index.md" ]] || continue
        
        local dirname
        dirname="$(basename "$month_dir")"
        local year="${dirname:0:4}"
        local month="${dirname:5:2}"
        
        # 统计文章数量
        local article_count
        article_count=$(find "$month_dir" -name "*.md" -not -name "_index.md" -type f | wc -l)
        
        cat >> "$cards_file" << CARD_EOF
<div class="month-card">
  <h3><a href="${dirname}">${year}年${month}月</a></h3>
  <p>收录 ${article_count} 篇AI日报，涵盖技术突破、产业动态、投资并购等关键资讯</p>
</div>
CARD_EOF
        # 修复：使用安全的递增方式
        month_count=$((month_count + 1))
    done
    
    # 如果没有数据，显示提示
    if [[ $month_count -eq 0 ]]; then
        cat > "$cards_file" << NO_DATA_EOF
<div class="no-data-card">
  <h3>暂无日报数据</h3>
  <p>AI每日简报正在筹备中，敬请期待...</p>
</div>
NO_DATA_EOF
    fi
    
    # 生成首页
    if sed "/{{MONTH_CARDS}}/r $cards_file" "$template_file" | \
        sed '/{{MONTH_CARDS}}/d' > "${CONTENT_DIR}/_index.md"; then
        log "Generated home page with $month_count months"
    else
        die "Failed to generate home page"
    fi
    
    # 清理临时文件
    rm -f "$cards_file"
}

# =============================================================================
# 主要功能函数
# =============================================================================

# 处理单个月份
process_month() {
    local month_dir="$1"
    local year="$2"
    local month="$3"
    
    log "Processing month: $year-$month"
    
    # 收集该月所有有效日期
    local dates=()
    while IFS= read -r date_str; do
        [[ -n "$date_str" ]] && dates+=("$date_str")
    done < <(collect_month_dates "$month_dir")
    
    if [[ ${#dates[@]} -eq 0 ]]; then
        log "No valid dates found for $year-$month, skipping..."
        return 0
    fi
    
    local dest_dir="${CONTENT_DIR}/${year}-${month}"
    mkdir -p "$dest_dir"
    
    # 生成每日页面
    for date_str in "${dates[@]}"; do
        generate_daily_page "$month_dir" "$dest_dir" "$date_str" || log "WARN: Failed to generate page for $date_str"
    done
    
    # 生成月份索引
    generate_month_index "$dest_dir" "$year" "$month" "${dates[@]}"
    
    log "Completed month: $year-$month (${#dates[@]} days)"
}

# 主同步函数
sync_content() {
    log "Starting content synchronization..."
    
    # 验证源目录
    [[ -d "$SOURCE_DIR" ]] || die "Source directory not found: $SOURCE_DIR"
    
    # 创建内容目录
    mkdir -p "$CONTENT_DIR"
    
    # 清理旧的生成内容（保留手动文件）
    find "$CONTENT_DIR" -name "20*" -type d -exec rm -rf {} + 2>/dev/null || true
    rm -f "${CONTENT_DIR}/_index.md"
    
    # 遍历年份目录
    local total_months=0
    for year_dir in "$SOURCE_DIR"/*/; do
        [[ -d "$year_dir" ]] || continue
        
        local year
        year="$(basename "$year_dir")"
        [[ "$year" =~ ^20[0-9]{2}$ ]] || {
            log "WARN: Skipping invalid year directory: $year"
            continue
        }
        
        # 遍历月份目录
        for month_dir in "$year_dir"/*/; do
            [[ -d "$month_dir" ]] || continue
            
            local month
            month="$(basename "$month_dir")"
            [[ "$month" =~ ^(0[1-9]|1[0-2])$ ]] || {
                log "WARN: Skipping invalid month directory: $month"
                continue
            }
            
            process_month "$month_dir" "$year" "$month"
            # 修复：使用安全的递增方式，避免在set -e模式下退出
            total_months=$((total_months + 1))
        done
    done
    
    log "Processed $total_months months"
    
    # 生成首页
    generate_home_page
    
    # 显示同步结果
    local total_files
    total_files=$(find "$CONTENT_DIR" -name "*.md" -type f 2>/dev/null | wc -l)
    log "Synchronization complete: $total_files files generated"
    
    # 列出生成的文件（限制输出）
    if [[ $total_files -gt 0 ]]; then
        log "Generated files:"
        find "$CONTENT_DIR" -name "*.md" -type f | sort | head -10
        if [[ $total_files -gt 10 ]]; then
            log "... and $((total_files - 10)) more files"
        fi
    fi
}

# =============================================================================
# 主程序入口
# =============================================================================

main() {
    log "AI News Content Sync v2.3"
    log "Project root: $PROJECT_ROOT"
    log "Source directory: $SOURCE_DIR"
    log "Content directory: $CONTENT_DIR"
    
    sync_content
    
    log "Sync process completed successfully"
}

# 执行主程序
main "$@"
