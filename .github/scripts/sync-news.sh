#!/bin/bash
# AI 快讯内容同步脚本
# 
# 功能：从ai-news-vault仓库同步markdown文件并生成Hugo站点内容
# 作者：AI 快讯团队
# 版本：2.4 - 简化生成逻辑，仅保留当天最新一次日报；显示原始标题（不追加更新时间）

set -euo pipefail

# =============================================================================
# 参数与环境（增量同步支持）
# =============================================================================

MODE="${SYNC_MODE:-auto}"           # auto|full|incremental
DATES_ARG=""                        # 逗号分隔的 YYYYMMDD 列表（来自 --dates 或 CHANGED_DATES 环境变量）
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}" # 无法检测变更时的兜底回溯天数
MAX_CHANGED_DAYS="${MAX_CHANGED_DAYS:-100}" # 变更多于该阈值时回退全量

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --mode=*)
                MODE="${arg#*=}"
                ;;
            --dates=*)
                DATES_ARG="${arg#*=}"
                ;;
            --lookback-days=*)
                LOOKBACK_DAYS="${arg#*=}"
                ;;
            --max-changed-days=*)
                MAX_CHANGED_DAYS="${arg#*=}"
                ;;
            *)
                # ignore unknown flags for forward-compat
                ;;
        esac
    done

    # 允许从环境变量传入日期
    if [[ -z "$DATES_ARG" ]] && [[ -n "${CHANGED_DATES:-}" ]]; then
        DATES_ARG="$CHANGED_DATES"
    fi

    # 标准化 MODE
    case "$MODE" in
        auto|full|incremental) ;;
        *) MODE="auto" ;;
    esac
}

# 将逗号/空白分隔的日期串转为数组，且去重、校验
to_date_array() {
    local input="$1"
    local out=()
    # 将逗号替换为空白，便于 for 循环
    input="${input//,/ }"
    for tok in $input; do
        if validate_date "$tok"; then
            out+=("$tok")
        fi
    done
    # 去重并以空格分隔输出，便于旧版 bash 解析
    if [[ ${#out[@]} -gt 0 ]]; then
        printf '%s\n' "${out[@]}" | sort -u | tr '\n' ' '
    fi
}

# =============================================================================
# 配置常量
# =============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly SOURCE_DIR="${PROJECT_ROOT}/source-news"
readonly CONTENT_DIR="${PROJECT_ROOT}/content"

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

## 已废弃：不再基于 pipeline slug 取显示名，直接使用源 Markdown 的 H1

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
# 不跳过首行 H1，而是将所有一级标题下调为 H2，避免页面出现多个 H1
for line in lines:
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

# 生成日报页面（支持多源合并）
generate_daily_page() {
    local month_dir="$1"
    local dest_dir="$2"
    local date_str="$3"

    eval "$(parse_date "$date_str")"
    local day_weight
    day_weight=$(calculate_weight "$year" "$month" "$day")

    log "Processing date: $date_str (${year}-${month}-${day})"

    # 收集当天所有来源的文件（兼容 bash 3.2，使用数组而非关联数组）
    local source_files=""
    local source_stamps=""
    local source_display_names=""
    local source_slugs=""
    local found_sources=0

    # 定义已知的数据源
    local known_sources="ai-briefing-twitter-list ai-briefing-hackernews ai-briefing-reddit"

    # 为每个数据源查找最新文件
    for source_slug in $known_sources; do
        local source_dir="$month_dir/$source_slug"
        [[ -d "$source_dir" ]] || continue

        local best_file=""
        local best_stamp=""

        while IFS= read -r -d '' file; do
            local filename="${file##*/}"

            if [[ "$filename" =~ ^briefing_([0-9]{8})T([0-9]{6})Z\.md$ ]]; then
                local file_date="${BASH_REMATCH[1]}"
                local time_part="${BASH_REMATCH[2]}"

                [[ "$file_date" == "$date_str" ]] || continue

                local stamp="${file_date}T${time_part}Z"
                if [[ -z "$best_stamp" || "$stamp" > "$best_stamp" ]]; then
                    best_stamp="$stamp"
                    best_file="$file"
                fi
            fi
        done < <(find "$source_dir" -maxdepth 1 -type f -name "briefing_${date_str}T*.md" -print0 2>/dev/null)

        # 如果找到该源的文件，加入列表
        if [[ -n "$best_file" ]]; then
            # 从源 Markdown 抽取 H1 作为显示名
            local display_name
            display_name="$(awk '/^# /{ sub(/^# /, ""); print; exit }' "$best_file" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            if [[ -z "$display_name" ]]; then
                # 将 slug 转换为可读形式作为回退
                case "$source_slug" in
                    "ai-briefing-twitter-list") display_name="AI 快讯 · Twitter" ;;
                    "ai-briefing-hackernews") display_name="AI 快讯 · Hacker News" ;;
                    "ai-briefing-reddit") display_name="AI 快讯 · Reddit" ;;
                    *) display_name="${source_slug//-/ }" ;;
                esac
            fi

            # 添加到列表（使用分隔符分隔）
            if [[ -z "$source_files" ]]; then
                source_files="$best_file"
                source_stamps="$best_stamp"
                source_display_names="$display_name"
                source_slugs="$source_slug"
            else
                source_files="$source_files|$best_file"
                source_stamps="$source_stamps|$best_stamp"
                source_display_names="$source_display_names|$display_name"
                source_slugs="$source_slugs|$source_slug"
            fi
            found_sources=$((found_sources + 1))

            log "  Found source: $source_slug -> $display_name (${best_stamp})"
        else
            log "  No files found for source: $source_slug"
        fi
    done

    # 如果没有找到任何源文件，跳过
    if [[ $found_sources -eq 0 ]]; then
        log "WARN: No briefing files found for date $date_str"
        return 1
    fi

    # 开始生成页面
    local daily_file="${dest_dir}/${year}-${month}-${day}.md"
    : > "$daily_file"

    # 生成 Front Matter
    echo "---" >> "$daily_file"
    echo "title: "${year}年${month}月${day}日 AI 快讯"" >> "$daily_file"
    echo "weight: $day_weight" >> "$daily_file"
    echo "date: ${year}-${month}-${day}" >> "$daily_file"
    echo "description: "AI 快讯 - ${year}年${month}月${day}日最新动态"" >> "$daily_file"

    # 创建临时文件来处理排序
    local temp_file="/tmp/source_sort_$$"
    echo "$source_stamps" | tr '|' '\n' > "$temp_file.stamps"
    echo "$source_files" | tr '|' '\n' > "$temp_file.files"
    echo "$source_display_names" | tr '|' '\n' > "$temp_file.names"
    echo "$source_slugs" | tr '|' '\n' > "$temp_file.slugs"

    # 合并并按时间戳排序
    paste "$temp_file.stamps" "$temp_file.files" "$temp_file.names" "$temp_file.slugs" | sort -k1 > "$temp_file.sorted"

    # 生成 sources 数组（按时间戳排序）
    echo "sources:" >> "$daily_file"
    cut -f3 "$temp_file.sorted" | while IFS= read -r display_name; do
        echo "  - $display_name" >> "$daily_file"
    done

    echo "source_slugs:" >> "$daily_file"
    cut -f4 "$temp_file.sorted" | while IFS= read -r slug; do
        echo "  - $slug" >> "$daily_file"
    done

    echo "toc: true" >> "$daily_file"
    echo "---" >> "$daily_file"

    # 渲染正文：按时间戳顺序合并所有源
    echo "" >> "$daily_file"

    # 按时间戳排序渲染源文件
    cut -f2 "$temp_file.sorted" | while IFS= read -r source_file; do
        # 渲染该源的内容
        render_markdown_body "$source_file" >> "$daily_file"
        echo "" >> "$daily_file"
    done

    # 清理临时文件
    rm -f "$temp_file"*

    log "Generated: $daily_file (sources: $found_sources)"
    log "  Sources: $(echo "$source_slugs" | tr '|' ' ')"
}

# 删除某天生成的页面（用于增量同步：当该日无源文件时清理旧产物）
delete_daily_page() {
    local dest_dir="$1"
    local date_str="$2"
    eval "$(parse_date "$date_str")"
    local daily_file="${dest_dir}/${year}-${month}-${day}.md"
    if [[ -f "$daily_file" ]]; then
        rm -f "$daily_file"
        log "Removed stale: $daily_file"
    fi
}

# 生成月份索引页面（简化版，无需模板）
generate_month_index() {
    local dest_dir="$1"
    local year="$2"
    local month="$3"
    local dates=("${@:4}")

    local weight
    weight=$(calculate_weight "$year" "$month")

    # 直接生成月份索引内容
    {
        echo "---"
        echo "title: \"${year}-${month}\""
        echo "weight: $weight"
        echo "breadcrumbs: false"
        echo "hideTitle: true"
        echo "sidebar:"
        echo "  open: true"
        echo "---"
        echo ""
        echo "<div class=\"newspaper-month-header border-b-4 border-double border-gray-900 dark:border-gray-100 pb-6 mb-8\">"
        echo "  <div class=\"text-center\">"
        echo "    <h1 class=\"page-title text-4xl md:text-5xl font-bold font-serif mb-2 text-gray-900 dark:text-gray-100\">"
        echo "      ${year}年${month}月"
        echo "    </h1>"
        echo "    <div class=\"sub-head-en text-lg md:text-xl text-gray-600 dark:text-gray-400 italic mb-4\">"
        echo "      AI DAILY BRIEFING ARCHIVE"
        echo "    </div>"
        echo "    <div class=\"lede-cn text-gray-600 dark:text-gray-400\">"
        echo "      本月收录 AI 行业重要动态，按日期归档整理"
        echo "    </div>"
        echo "  </div>"
        echo "</div>"
        echo ""
        echo "<div class=\"newspaper-daily-list hx-mt-12\">"
        echo "  <h2 class=\"section-title text-2xl font-bold mb-6 font-serif flex items-center\">"
        echo "    <span class=\"mr-3\">📰</span>"
        echo "    本月日报"
        echo "    <span class=\"en ml-auto text-sm font-normal text-gray-500\">"
        echo "      Daily AI Briefings"
        echo "    </span>"
        echo "  </h2>"
        echo "  "
        echo "  <div class=\"newspaper-articles-grid\">"

        # 生成日报链接
        for date_str in "${dates[@]}"; do
            eval "$(parse_date "$date_str")"
            echo "<div class=\"daily-article\">"
            echo "  <a href=\"${year}-${month}-${day}\">${month}-${day} 日报</a>"
            echo "</div>"
        done

        echo "  </div>"
        echo "</div>"
    } > "${dest_dir}/_index.md"

    log "Generated month index: ${dest_dir}/_index.md"
}

# 生成首页（直接显示最新日报内容）
generate_home_page() {
    log "Starting home page generation..."

    # 查找最新的日报文件
    local latest_file
    latest_file=$(find "$CONTENT_DIR" -name "*.md" -path "*/20??-??/20??-??-??.md" -type f | sort -r | head -1)

    if [[ -z "$latest_file" ]]; then
        log "WARN: No daily report files found, creating placeholder home page"
        cat > "${CONTENT_DIR}/_index.md" << NO_DATA_EOF
---
title: AI 快讯 - 您的人工智能情报站
linkTitle: AI 快讯
breadcrumbs: false
description: "每天 3 分钟，速览全球 AI 关键信息。自动聚合公开权威源，事件聚类 + LLM 摘要，原文一键直达；支持网站、RSS 与 Telegram 订阅。"
cascade:
  type: docs
---

## 暂无日报数据

AI 快讯正在筹备中，敬请期待...
NO_DATA_EOF
        return 0
    fi

    # 复制最新日报内容到首页
    cp "$latest_file" "${CONTENT_DIR}/_index.md"

    # 修改首页的 frontmatter，保持首页属性
    local temp_file="${CONTENT_DIR}/.homepage_tmp"
    local in_frontmatter=false
    local frontmatter_ended=false

    {
        echo "---"
        echo "linkTitle: AI 快讯"
        echo "breadcrumbs: false"
        echo "description: \"每天 3 分钟，速览全球 AI 关键信息。自动聚合公开权威源，事件聚类 + LLM 摘要，原文一键直达；支持网站、RSS 与 Telegram 订阅。\""
        echo "cascade:"
        echo "  type: docs"
        echo "---"

        # 输出日报正文内容（跳过原始的 frontmatter）
        while IFS= read -r line; do
            if [[ "$line" == "---" ]]; then
                if [[ "$in_frontmatter" == false ]]; then
                    in_frontmatter=true
                    continue
                elif [[ "$frontmatter_ended" == false ]]; then
                    frontmatter_ended=true
                    continue
                fi
            fi

            if [[ "$frontmatter_ended" == true ]]; then
                echo "$line"
            fi
        done < "$latest_file"
    } > "$temp_file"

    mv "$temp_file" "${CONTENT_DIR}/_index.md"

    log "Generated home page from latest report: $(basename "$latest_file")"
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

# 全量同步函数（兼容旧逻辑）
sync_content_full() {
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

# 增量同步：仅处理受影响的日期和对应月份
sync_content_incremental() {
    log "Starting incremental synchronization..."

    [[ -d "$SOURCE_DIR" ]] || die "Source directory not found: $SOURCE_DIR"
    mkdir -p "$CONTENT_DIR"

    # 解析受影响日期（空格分隔）
    local dates_str
    dates_str="$(to_date_array "$DATES_ARG")"
    # shellcheck disable=SC2206
    local dates=( $dates_str )

    if [[ ${#dates[@]} -eq 0 ]]; then
        log "No valid changed dates provided; nothing to update"
        # 兜底：仍然刷新首页，保持统计与导航更新
        generate_home_page
        return 0
    fi

    # 变更过多时回退全量
    if [[ ${#dates[@]} -gt ${MAX_CHANGED_DAYS} ]]; then
        log "Changed days (${#dates[@]}) exceed threshold (${MAX_CHANGED_DAYS}); falling back to full rebuild"
        sync_content_full
        return 0
    fi

    # 收集受影响的月份集合（后续再去重）
    local affected_months=()

    for date_str in "${dates[@]}"; do
        eval "$(parse_date "$date_str")"

        local month_src_dir="${SOURCE_DIR}/${year}/${month}"
        local dest_dir="${CONTENT_DIR}/${year}-${month}"
        mkdir -p "$dest_dir"

        # 生成当日页面；如无源文件则删除既有页面
        if generate_daily_page "$month_src_dir" "$dest_dir" "$date_str"; then
            :
        else
            delete_daily_page "$dest_dir" "$date_str"
        fi

        affected_months+=("${year}-${month}")
    done

    # 去重月份
    if [[ ${#affected_months[@]} -gt 0 ]]; then
        # 使用临时文件进行去重，兼容旧版 bash
        local _tmp_months
        _tmp_months=$(printf '%s\n' "${affected_months[@]}" | sort -u)
        # 重新装入数组
        # shellcheck disable=SC2206
        affected_months=( $_tmp_months )
    fi

    # 更新受影响月份的索引
    for ym in "${affected_months[@]}"; do
        local y="${ym%-*}"
        local m="${ym#*-}"
        local month_src_dir="${SOURCE_DIR}/${y}/${m}"
        local dest_dir="${CONTENT_DIR}/${ym}"

        # 收集该月所有有效日期（从源目录重新计算）
        local month_dates=()
        if [[ -d "$month_src_dir" ]]; then
            while IFS= read -r date_str; do
                [[ -n "$date_str" ]] && month_dates+=("$date_str")
            done < <(collect_month_dates "$month_src_dir")
        fi

        if [[ ${#month_dates[@]} -eq 0 ]]; then
            # 若该月已无任何源数据，清理目标目录
            if [[ -d "$dest_dir" ]]; then
                rm -rf "$dest_dir"
                log "Removed empty month directory: $dest_dir"
            fi
        else
            mkdir -p "$dest_dir"
            generate_month_index "$dest_dir" "$y" "$m" "${month_dates[@]}"
        fi
    done

    # 刷新首页
    generate_home_page

    # 汇总输出
    local total_files
    total_files=$(find "$CONTENT_DIR" -name "*.md" -type f 2>/dev/null | wc -l)
    log "Incremental synchronization complete: $total_files files now present"
}

# =============================================================================
# 主程序入口
# =============================================================================

main() {
    log "AI News Content Sync v2.4"
    log "Project root: $PROJECT_ROOT"
    log "Source directory: $SOURCE_DIR"
    log "Content directory: $CONTENT_DIR"
    
    parse_args "$@"
    log "Mode: $MODE"
    if [[ -n "$DATES_ARG" ]]; then
        log "Changed dates: $DATES_ARG"
    fi

    case "$MODE" in
        full)
            sync_content_full
            ;;
        incremental)
            sync_content_incremental
            ;;
        auto)
            # 有变更日期则走增量，否则全量
            if [[ -n "$DATES_ARG" ]]; then
                sync_content_incremental
            else
                sync_content_full
            fi
            ;;
    esac

    log "Sync process completed successfully"
}

# 执行主程序
main "$@"
