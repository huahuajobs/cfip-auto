#!/bin/bash
# 只获取IP的机场代码(COLO)，不测速

cd "$(dirname "$0")"

# 机场代码对应中文地名
declare -A COLO_MAP=(
    ["HKG"]="香港" ["NRT"]="日本东京" ["KIX"]="日本大阪" ["ICN"]="韩国首尔"
    ["SIN"]="新加坡" ["TPE"]="台湾台北" ["KHH"]="台湾高雄" ["BKK"]="泰国曼谷"
    ["SYD"]="澳大利亚悉尼" ["LAX"]="美国洛杉矶" ["SJC"]="美国圣何塞" ["SEA"]="美国西雅图"
    ["IAD"]="美国华盛顿" ["ORD"]="美国芝加哥" ["DFW"]="美国达拉斯" ["ATL"]="美国亚特兰大"
    ["MIA"]="美国迈阿密" ["EWR"]="美国纽瓦克" ["FRA"]="德国法兰克福" ["LHR"]="英国伦敦"
    ["CDG"]="法国巴黎" ["AMS"]="荷兰阿姆斯特丹" ["MAD"]="西班牙马德里"
)

INPUT_FILE="${1:-passed_ips.txt}"
OUTPUT_TXT="result_colo.txt"

echo "=========================================="
echo "  Cloudflare IP 机场代码检测工具"
echo "=========================================="
echo ""

if [ ! -f "$INPUT_FILE" ]; then
    echo "错误: 文件 $INPUT_FILE 不存在"
    exit 1
fi

IP_COUNT=$(wc -l < "$INPUT_FILE" | tr -d ' ')
echo "输入文件: $INPUT_FILE ($IP_COUNT 个IP)"
echo ""

> "$OUTPUT_TXT"
SUCCESS=0
FAILED=0

while IFS= read -r ip || [ -n "$ip" ]; do
    [ -z "$ip" ] && continue
    ip=$(echo "$ip" | tr -d '\r ')
    
    # 获取COLO
    colo=$(curl -s --connect-timeout 2 -m 3 "http://$ip/cdn-cgi/trace" 2>/dev/null | grep -oP 'colo=\K[A-Z]+')
    
    if [ -n "$colo" ]; then
        cn_name="${COLO_MAP[$colo]:-$colo}"
        echo "${ip}#${cn_name}" >> "$OUTPUT_TXT"
        echo "✓ $ip → $colo ($cn_name)"
        ((SUCCESS++))
    else
        echo "✗ $ip → 无法获取"
        ((FAILED++))
    fi
done < "$INPUT_FILE"

echo ""
echo "=========================================="
echo "  完成！成功: $SUCCESS, 失败: $FAILED"
echo "=========================================="
echo ""
echo "结果文件: $OUTPUT_TXT"

