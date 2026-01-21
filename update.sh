#!/bin/bash
# Cloudflare 优选 IP 自动化脚本 v9.8
# 特性：
# 1. 准入双轨制 & 动态地区 & 纯延迟排序
# 2. 优选域名双轨制: 
#    - 直连测速 (HTTPS->HTTP)
#    - 失败保活: 直连失败不删除，转入代理模式识别 COLO (延迟记为 9999)
# 3. 强制 IPv4: 避免直连模式下 IPv6 不稳导致超时
# 4. 兼容性: 修复 BusyBox find 命令报错

set -uo pipefail

# 基础配置
WORK_DIR="/root/cfip"
CFST_BIN="./CloudflareST"
LATENCY_LIMIT=200
LOG_FILE="update.log"
GIT_EMAIL="cfip@router.local"
GIT_NAME="CFIP Bot"

# 地区映射
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
    "https://cf.090227.xyz/ct?ips=6"
    "https://cf.090227.xyz/ip.164746.xyz"
)

# 3. 优选域名列表
CUSTOM_DOMAINS=(
    "bestcf.030101.xyz"
    "cdn.2020111.xyz"
    "cdns.doon.eu.org"
    "cf.0sm.com"
    "cf.877771.xyz"
    "cf.877774.xyz"
    "cf.900501.xyz"
    "cfip.1323123.xyz"
    "cfip.cfcdn.vip"
    "cfip.xxxxxxxx.tk"
    "cloudflare.182682.xyz"
    "cloudflare-dl.byoip.top"
    "cloudflare-ip.mofashi.ltd"
    "fn.130519.xyz"
    "freeyx.cloudflare88.eu.org"
    "nrt.xxxxxxxx.nyc.mn"
    "nrtcfdns.zone.id"
    "saas.sin.fan"
    "tencentapp.cn"
    "xn--b6gac.eu.org"
    "777.ai7777777.xyz"
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
    log_info "VIP IP: $(wc -l < vip_input.txt) | 普通 IP: $(wc -l < normal_input.txt)"
}

test_and_identify() {
    log_info "第2步: 直连测速 & 识别 (IP + 域名)..."
    [ ! -x "$CFST_BIN" ] && { log_error "CloudflareST 不存在"; exit 1; }
    
    # 启用直连
    log_info "  > 启用直连规则"
    nft insert rule inet fw4 openclash_mangle_output counter return comment "CFIP_DIRECT" 2>/dev/null
    sleep 2
    
    # === A. IP 测速部份 ===
    if [ -s vip_input.txt ]; then
        log_info "  测速 VIP IP (TL: 9999)..."
        $CFST_BIN -f vip_input.txt -tl 9999 -dd -dn 0 -o tested_vip.csv 2>&1 >/dev/null
    fi
    if [ -s normal_input.txt ]; then
        log_info "  测速 普通 IP (TL: $LATENCY_LIMIT)..."
        $CFST_BIN -f normal_input.txt -tl "$LATENCY_LIMIT" -dd -dn 1000 -o tested_normal.csv 2>&1 >/dev/null
    fi
    
    # === B. 域名测速部分 ===
    log_info "  测速优选域名..."
    > domain_results.txt
    > failed_domains.txt
    local d_total=${#CUSTOM_DOMAINS[@]}
    local d_curr=0
    
    for domain in "${CUSTOM_DOMAINS[@]}"; do
        ((d_curr++))
        # 1. 优先尝试 HTTPS (强制 IPv4, 忽略证书错误 -k)
        output=$(curl -4 -k -s --connect-timeout 2 -m 3 -w "|%{time_connect}" "https://$domain/cdn-cgi/trace")
        
        # 2. 如果 HTTPS 失败，回退尝试 HTTP
        if [[ "$output" != *"colo="* ]]; then
             output=$(curl -4 -s --connect-timeout 2 -m 3 -w "|%{time_connect}" "http://$domain/cdn-cgi/trace")
        fi
        
        # 检查是否请求成功
        if [[ "$output" == *"colo="* ]]; then
            latency_sec=$(echo "$output" | tail -n1 | cut -d'|' -f2)
            latency=$(awk -v t="$latency_sec" 'BEGIN {printf "%d", t*1000}')
            colo=$(echo "$output" | grep -o "colo=[A-Z]*" | cut -d= -f2)
            
            cn_name="$colo"
            if [ -n "$colo" ]; then
                info="${COLO_INFO[$colo]:-}"
                [ -n "$info" ] && cn_name="${info%|*}"
            else
                cn_name="UNKNOWN"
            fi
            
            echo "$domain|$latency|$cn_name" >> domain_results.txt
            log_info "    $d_curr/$d_total: $domain ($latency ms) -> $cn_name"
        else
            # 记录失败域名，稍后用代理回退识别
            echo "$domain" >> failed_domains.txt
            log_warn "    $d_curr/$d_total: $domain 直连失败 -> 稍后代理识别"
        fi
    done
    echo ""

    # === C. IP 识别与聚合 ===
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

    # === D. 失败域名回退识别 (代理模式) ===
    if [ -s failed_domains.txt ]; then
        log_info "  正在通过代理识别直连失败的域名..."
        while read -r domain; do
            # 代理模式下尝试获取 COLO (不做强制 IPv4，让系统代理决定)
            output=$(curl -k -s --connect-timeout 3 -m 5 "https://$domain/cdn-cgi/trace")
            if [[ "$output" != *"colo="* ]]; then
                 output=$(curl -s --connect-timeout 3 -m 5 "http://$domain/cdn-cgi/trace")
            fi
            
            colo=$(echo "$output" | grep -o "colo=[A-Z]*" | cut -d= -f2)
            cn_name="$colo"
            if [ -n "$colo" ]; then
                info="${COLO_INFO[$colo]:-}"
                [ -n "$info" ] && cn_name="${info%|*} (代理)"
            else
                cn_name="无法连接"
            fi
            
            # 失败域名强制延迟 9999
            echo "$domain|9999|$cn_name" >> domain_results.txt
            log_warn "    - $domain -> $cn_name (延迟: 9999)"
        done < failed_domains.txt
    fi

    # === E. 生成文件 ===
    log_info "  生成分类文件..."
    > All.txt
    
    # 1. IP 地区文件
    EXISTING_CODES=$(cut -d'|' -f4 raw_data.txt | grep -vE "UNKNOWN|OTHER" | sort -u)
    if [ -n "$EXISTING_CODES" ]; then
        for code in $EXISTING_CODES; do
            grep "|$code$" raw_data.txt | sort -t "|" -k2,2n | head -n 20 | awk -F"|" '{print $1"#" $3}' > "${code}.txt"
            grep "|$code$" raw_data.txt | sort -t "|" -k2,2n | head -n 10 | awk -F"|" '{print $1"#" $3}' >> All.txt
            log_info "    - ${code}.txt"
        done
    fi
    
    # 2. 优选域名.txt (单独输出)
    if [ -s domain_results.txt ]; then
        sort -t "|" -k2,2n domain_results.txt | awk -F"|" '{print $1"#" $3}' > "优选域名.txt"
        count=$(wc -l < "优选域名.txt")
        log_info "    - 优选域名.txt: $count 个"
    else
        log_warn "    - 优选域名: 无可用结果"
        > "优选域名.txt"
    fi
    
    # 清理
    rm -f raw_data.txt merged.csv tested_*.csv raw_*.txt *_input.txt passed_ips.txt vip.txt domain_results.txt failed_domains.txt
    # 删除空文件 (兼容 BusyBox)
    for f in *.txt; do
        [ -s "$f" ] || rm -f "$f"
    done
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
        git commit -m "优选 v9.8: 域名失败保活 & 代理识别 - $(date '+%Y-%m-%d %H:%M')"
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
    log_info "========== v9.8 保活增强版 =========="
    cleanup_env
    fetch_ip_sources
    test_and_identify
    git_push
    log_ok "========== 全部完成 =========="
}

main "$@"
