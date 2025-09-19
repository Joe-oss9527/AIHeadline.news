#!/bin/bash
# AI每日简报内容同步脚本
# 
# 功能：从ai-news-vault仓库同步markdown文件并生成Hugo站点内容
# 作者：AI每日简报团队
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

# 生成日报页面
generate_daily_page() {
    local month_dir="$1"
    local dest_dir="$2"
    local date_str="$3"

    eval "$(parse_date "$date_str")"
    local day_weight
    day_weight=$(calculate_weight "$year" "$month" "$day")

    # 选择当天最新的一份（跨管道取最大时间戳）
    local selected_file=""
    local selected_pipeline=""
    local best_stamp=""

    while IFS= read -r -d '' file; do
        local rel="${file#${month_dir}/}"
        local pipeline="${rel%%/*}"
        local filename="${file##*/}"

        if [[ "$filename" =~ ^briefing_([0-9]{8})T([0-9]{6})Z\.md$ ]]; then
            local file_date="${BASH_REMATCH[1]}"
            local time_part="${BASH_REMATCH[2]}"

            [[ "$file_date" == "$date_str" ]] || continue

            local stamp="${file_date}T${time_part}Z"
            if [[ -z "$best_stamp" || "$stamp" > "$best_stamp" ]]; then
                best_stamp="$stamp"
                selected_file="$file"
                selected_pipeline="$pipeline"
            fi
        else
            log "WARN: Unrecognized filename format: $filename"
        fi
    done < <(find "$month_dir" -mindepth 2 -maxdepth 2 -type f -name "briefing_${date_str}T*.md" -print0 2>/dev/null)

    if [[ -z "$selected_file" ]]; then
        log "WARN: No briefing files found for date $date_str"
        return 1
    fi

    # 已选择最新一份，开始写入页面

    local daily_file="${dest_dir}/${year}-${month}-${day}.md"
    : > "$daily_file"

    echo "---" >> "$daily_file"
    echo "title: "${year}年${month}月${day}日 AI 简报"" >> "$daily_file"
    echo "weight: $day_weight" >> "$daily_file"
    echo "date: ${year}-${month}-${day}" >> "$daily_file"
    echo "description: "AI每日简报 - ${year}年${month}月${day}日最新动态"" >> "$daily_file"

    # 单一来源，无需排序

    # 从源 Markdown 抽取 H1 作为来源名，若缺失则回退到 slug 的可读形式
    local display_name
    display_name="$(awk '/^# /{ sub(/^# /, ""); print; exit }' "$selected_file" | sed 's/^\s*//; s/\s*$//')"
    if [[ -z "$display_name" ]]; then
        # 将 slug 中的连字符替换为空格作为简易回退
        display_name="${selected_pipeline//-/ }"
    fi
    echo "sources:" >> "$daily_file"
    echo "  - $display_name" >> "$daily_file"
    echo "source_slugs:" >> "$daily_file"
    echo "  - $selected_pipeline" >> "$daily_file"

    echo "toc: true" >> "$daily_file"
    echo "---" >> "$daily_file"

    # 渲染正文：仅一份来源（保留源文件 H1，已在渲染中降级为 H2）
    {
        echo ""
        render_markdown_body "$selected_file"
        echo ""
    } >> "$daily_file"

    log "Generated: $daily_file"
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
