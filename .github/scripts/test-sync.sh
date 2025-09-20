#!/bin/bash
# 本地测试脚本 - 从 ai-news-vault 获取数据并同步

echo "=== AI News Hugo 本地测试脚本 ==="

# 初始化或更新子模块
if [ ! -d "source-news" ] || [ ! -f "source-news/.git" ]; then
    echo "初始化 ai-briefing-archive 子模块..."
    git submodule update --init --depth 1 source-news
else
    echo "更新 ai-briefing-archive 子模块..."
    git -C source-news pull --ff-only
fi

# 清理旧的测试内容
echo "清理旧的测试内容..."
rm -rf content/20*

# 使用同样的同步脚本
echo "开始同步新闻文件..."
./.github/scripts/sync-news.sh

echo ""
echo "运行 'hugo server' 启动本地服务器进行测试"
