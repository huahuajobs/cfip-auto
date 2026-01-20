#!/bin/bash
# Cloudflare 优选 IP 自动化脚本 v9.3
# 特性：
# 1. 准入双轨制：VIP 源宽松测速(保活)，普通源严格测速(优选)。
# 2. 动态生成区：只生成实际存在的地区文件，不生成空文件。
# 3. 选拔一视同仁：进入候选池后，完全按延迟由低到高排序。
#    - All.txt: 汇总所有存在地区，每个地区延迟最低 Top 10
#    - [地区].txt: 动态生成实际存在的地区文件 (如 JP.txt)，Top 20

set -uo pipefail

# 基础配置
WORK_DIR="/root/cfip"
CFST_BIN="./CloudflareST"
LATENCY_LIMIT=200
LOG_FILE="update.log"
GIT_EMAIL="cfip@router.local"
GIT_NAME="CFIP Bot"

# 地区映射 & 国家代码
# 格式: ["COLO"]="中文名|国家代码"
declare -A COLO_INFO=(
    ["HKG"]="香港|HK" ["NRT"]="日本东京|JP" ["KIX"]="日本大阪|JP" ["ICN"]="韩国首尔|KR"
    ["SIN"]="新加坡|SG" ["TPE"]="台湾台北|TW" ["KHH"]="台湾高雄|TW" ["BKK"]="泰国曼谷|TH"
    ["SYD"]="澳大利亚悉尼|AU" ["LAX"]="美国洛杉矶|US" ["SJC"]="美国圣何塞|US" ["SEA"]="美国西雅图|US"
    ["IAD"]="美国华盛顿|US" ["ORD"]="美国芝加哥|US" ["DFW"]="美国达拉斯|US" ["ATL"]="美国亚特兰大|US"
    ["MIA"]="美国迈阿密|US" ["EWR"]="美国纽瓦克|US" ["FRA"]="德国法兰克福|DE" ["LHR"]="英国伦敦|UK"
    ["CDG"]="法国巴黎|FR" ["AMS"]="荷兰阿姆斯特丹|NL" ["MAD"]="西班牙马德里|ES"
)

# 1. VIP 源
VIP_SOURCE="https://ip.164746.xyz/ipTop10.html"

# 2. 普通源
NORMAL_SOURCES=(
    "https://raw.githubusercontent.com/chris202010/yxym/refs/heads/main/ip.txt"
    "https://raw.githubusercontent.com/gslege/CloudflareIP/refs/heads/main/All.txt"
    "https://raw.githubusercontent.com/gslege/CloudflareIP/refs/heads/main/JP.txt"
    "https://raw.githubusercontent.com/gslege/CloudflareIP/refs/heads/main/country.txt"
    "https://raw.githubusercontent.com/cys92096/cfipcaiji/refs/heads/main/ip.txt"
    "https://raw.githubusercontent.com/Jackiegee857/yx777/refs/heads/main/speed_ip.txt"
    "https://raw.githubusercontent.com/vipmc838/cf_best_ip/refs/heads/main/cloudflare_bestip.txt"
    "https://raw.githubusercontent.com/946727185/auto-ip-update/refs/heads/main/%E4%BC%98%E9%80%89ip.txt"
    "https://raw.githubusercontent.com/KafeMars/best-ips-domains/refs/heads/main/cf-bestips.txt"
    "https://raw.githubusercontent.com/lu-lingyun/CloudflareST/refs/heads/main/TLS.txt"
    "https://raw.githubusercontent.com/fangke1982/yx/refs/heads/main/jp.txt"
    "https://raw.githubusercontent.com/fangke1982/yx/refs/heads/main/ips.txt"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${@:2}" | tee -a "$LOG_FILE"; }
log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_ok() { log "OK" "$@"; }
log_error() { log "ERROR" "$@"; }

cleanup_env() {
    log_info "初始化环境..."
    while true; do
        handle=$(nft -a list chain inet fw4 openclash_mangle_output 2>/dev/null | grep 'comment "CFIP_DIRECT"' | head -1 | sed -n 's/.*handle \([0-9]*\).*/\1/p')
        [ -z "$handle" ] && break
        log_warn "删除残留规则 handle: $handle"
        nft delete rule inet fw4 openclash_mangle_output handle $handle 2>/dev/null
    done
}

fetch_ip_sources() {
    log_info "第1步: 下载 IP 源..."
    curl -sL --connect-timeout 8 -m 20 "$VIP_SOURCE" > raw_vip.txt 2>/dev/null
    > raw_normal.txt
    for url in "${NORMAL_SOURCES[@]}"; do
        curl -sL --connect-timeout 8 -m 20 "$url" >> raw_normal.txt 2>/dev/null
    done
    clean_file() {
        grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$1" | awk -F. '$1>=1 && $1<=255 && $2<=255 && $3<=255 && $4<=255 && $1!~/^0/' | sort -u > "$2"
    }
    clean_file raw_vip.txt vip_input.txt
    clean_file raw_normal.txt normal_input.txt
    log_info "VIP: $(wc -l < vip_input.txt) | 普通: $(wc -l < normal_input.txt)"
}

test_and_identify() {
    log_info "第2步: 双轨测速 & 识别 & 竞价排序..."
    [ ! -x "$CFST_BIN" ] && { log_error "CloudflareST 不存在"; exit 1; }
    
    # A. 直连测速
    log_info "  > 启用直连规则"
    nft insert rule inet fw4 openclash_mangle_output counter return comment "CFIP_DIRECT" 2>/dev/null
    sleep 2
    
    # VIP 宽松测速
    if [ -s vip_input.txt ]; then
        log_info "  测速 VIP (TL: 9999)..."
        $CFST_BIN -f vip_input.txt -tl 9999 -dd -dn 0 -o tested_vip.csv 2>&1 >/dev/null
    fi
    # 普通严格测速
    if [ -s normal_input.txt ]; then
        log_info "  测速 普通 (TL: $LATENCY_LIMIT)..."
        $CFST_BIN -f normal_input.txt -tl "$LATENCY_LIMIT" -dd -dn 1000 -o tested_normal.csv 2>&1 >/dev/null
    fi

    # B. 合并数据池
    > raw_data.txt
    > merged.csv
    [ -s tested_vip.csv ] && tail -n +2 tested_vip.csv >> merged.csv
    [ -s tested_normal.csv ] && tail -n +2 tested_normal.csv >> merged.csv
    sort -u -t, -k1,1 merged.csv -o merged.csv
    
    total=$(wc -l < merged.csv)
    log_info "  开始识别 $total 个有效 IP..."
    
    current=0
    while IFS=, read -r ip sent recv loss ping rest; do
        ((current++))
        colo=$(curl -s --connect-timeout 2 -m 3 "http://$ip/cdn-cgi/trace" | grep "colo=" | cut -d= -f2)
        
        cn_name="未知"
        country="UNKNOWN"
        
        if [ -n "$colo" ]; then
            info="${COLO_INFO[$colo]:-}"
            if [ -n "$info" ]; then
                cn_name="${info%|*}"
                country="${info#*|}"
            else
                cn_name="$colo"
                country="OTHER"
            fi
        fi
        
        echo "$ip|$ping|$cn_name|$country" >> raw_data.txt
        
        [ $((current % 10)) -eq 0 ] && echo -ne "  进度: $current/$total\r"
    done < merged.csv
    echo ""

    log_info "  < 恢复代理模式"
    handle=$(nft -a list chain inet fw4 openclash_mangle_output 2>/dev/null | grep 'comment "CFIP_DIRECT"' | head -1 | sed -n 's/.*handle \([0-9]*\).*/\1/p')
    [ -n "$handle" ] && nft delete rule inet fw4 openclash_mangle_output handle $handle 2>/dev/null

    # C. 动态生成分类文件
    log_info "  动态生成地区文件 (Top20)..."
    > All.txt
    
    # scan for existing country codes
    EXISTING_CODES=$(cut -d'|' -f4 raw_data.txt | grep -vE "UNKNOWN|OTHER" | sort -u)
    
    if [ -n "$EXISTING_CODES" ]; then
        echo "识别到的地区: $EXISTING_CODES" | tr '\n' ' '
        echo ""
        
        for code in $EXISTING_CODES; do
            # 生成地区文件: 纯 Ping 排序, 取前 20
            grep "|$code$" raw_data.txt | sort -t "|" -k2,2n | head -n 20 | awk -F"|" '{print $1"#" $3}' > "${code}.txt"
            
            # 追加到 All.txt: 纯 Ping 排序, 取前 10
            grep "|$code$" raw_data.txt | sort -t "|" -k2,2n | head -n 10 | awk -F"|" '{print $1"#" $3}' >> All.txt
            
            count=$(wc -l < "${code}.txt")
            log_info "    - ${code}.txt: $count 个"
        done
    fi
    
    rm -f raw_data.txt merged.csv tested_*.csv raw_*.txt *_input.txt passed_ips.txt vip.txt
    
    # 删除空文件
    find . -maxdepth 1 -name "*.txt" -size 0 -delete
}

git_push() {
    log_info "第3步: Git 推送..."
    git config --local --unset http.proxy 2>/dev/null || true
    git config --local --unset https.proxy 2>/dev/null || true
    git config --local user.email "$GIT_EMAIL"
    git config --local user.name "$GIT_NAME"

    rm -f vip.txt
    
    git add -A
    if git diff --cached --quiet; then
        log_info "无变化，跳过"
    else
        git commit -m "优选 v9.3: 动态地区+纯延迟 - $(date '+%Y-%m-%d %H:%M')"
        for i in {1..10}; do
            if git push origin main 2>&1 >/dev/null; then
                log_ok "推送成功"
                return 0
            fi
            log_warn "推送重试 ($i/10)..."
            sleep 5
        done
        log_error "推送失败"
    fi
}

main() {
    cd "$WORK_DIR" || exit 1
    log_info "========== v9.3 动态纯延迟版 =========="
    cleanup_env
    fetch_ip_sources
    test_and_identify
    git_push
    log_ok "========== 全部完成 =========="
}

main "$@"
