#!/bin/sh
# ============================================================================
# 上传构建产物到 OpenList 软件源
# ============================================================================
set -e

if [ -z "$OPENLIST_TOKEN" ]; then
        echo "错误: 未提供 OPENLIST_TOKEN 环境变量"
        exit 1
fi

DIST_DIR="${1:-dist}"
if [ ! -d "$DIST_DIR" ]; then
        echo "错误: 产物目录不存在: $DIST_DIR"
        exit 1
fi

API_URL="https://list.910501.xyz/api/packages"
UPLOAD_FILES=$(find "$DIST_DIR" -type f -name "*.run" -o -name "*.ipk" 2>/dev/null)

if [ -z "$UPLOAD_FILES" ]; then
        echo "错误: 在 $DIST_DIR 中没有找到 .run 或 .ipk 文件"
        exit 1
fi

echo "找到以下文件准备上传:"
echo "$UPLOAD_FILES"

for file in $UPLOAD_FILES; do
        filename=$(basename "$file")
        echo "--------------------------------------------------"
        echo "正在上传: $filename"
        
        RESPONSE=$(curl -s -X POST "$API_URL" \
                -H "Authorization: Bearer $OPENLIST_TOKEN" \
                -F "file=@$file")
        
        HTTP_CODE=$(echo "$RESPONSE" | grep -o 'HTTP/1.1 [0-9]*' | awk '{print $2}')
        if echo "$RESPONSE" | grep -q '"success":true' || echo "$RESPONSE" | grep -q 'ok'; then
                echo "✅ 上传成功: $filename"
        else
                echo "❌ 上传失败: $filename"
                echo "返回内容: $RESPONSE"
                exit 1
        fi
done

echo "=================================================="
echo "🎉 所有文件已成功上传至 OpenList!"
