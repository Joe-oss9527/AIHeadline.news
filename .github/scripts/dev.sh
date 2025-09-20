#!/bin/bash

# 获取项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=== AI Headline 本地开发一键启动脚本 ==="
echo "📁 项目根目录: ${PROJECT_ROOT}"
echo ""

# 切换到项目根目录
cd "${PROJECT_ROOT}"

# 1. 杀死可能正在运行的 Hugo 进程
echo "🔄 停止现有的 Hugo 进程..."
pkill -f "hugo server" 2>/dev/null || true
pkill -f "hugo" 2>/dev/null || true
sleep 1

# 2. 运行测试同步脚本
echo "📰 同步最新新闻数据..."
chmod +x .github/scripts/test-sync.sh
./.github/scripts/test-sync.sh

# 检查同步是否成功
if [ $? -eq 0 ]; then
    echo "✅ 数据同步完成"
else
    echo "❌ 数据同步失败，但继续启动服务器..."
fi

echo ""
echo "🚀 启动 Hugo 开发服务器..."
echo "📝 访问 http://localhost:1313 查看网站"
echo "💡 按 Ctrl+C 停止服务器"
echo ""

# 3. 启动 Hugo 服务器
hugo server --buildDrafts --buildFuture --disableFastRender --navigateToChanged 