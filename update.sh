#!/bin/bash
# Cloudflare 优选 IP 自动化脚本 v3.3

set -uo pipefail

WORK_DIR="/root/cfip"
CFST_BIN="./CloudflareST"
LATENCY_LIMIT=200
OUTPUT_FILE="result.txt"
LOG_FILE="update.log"
GIT_EMAIL="cfip@router.local"
GIT_NAME="CFIP Bot"

IP_SOURCES=(
    "https://ip.164746.xyz/ipTop10.html"
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

declare -A COLO_MAP=(
    ["SJC"]="圣何塞" ["LAX"]="洛杉矶" ["SEA"]="西雅图"
    ["ORD"]="芝加哥" ["DFW"]="达拉斯" ["IAD"]="华盛顿"
    ["MIA"]="迈阿密" ["ATL"]="亚特兰大" ["JFK"]="纽约"
    ["EWR"]="纽瓦克" ["BOS"]="波士顿" ["DEN"]="丹佛"
    ["PHX"]="凤凰城" ["SLC"]="盐湖城" ["PDX"]="波特兰"
    ["YYZ"]="多伦多" ["YVR"]="温哥华" ["YUL"]="蒙特利尔"
    ["LHR"]="伦敦" ["FRA"]="法兰克福" ["AMS"]="阿姆斯特丹"
    ["CDG"]="巴黎" ["MAD"]="马德里" ["MXP"]="米兰"
    ["NRT"]="东京" ["KIX"]="大阪" ["ICN"]="首尔"
    ["SIN"]="新加坡" ["HKG"]="香港" ["TPE"]="台北"
    ["SYD"]="悉尼" ["MEL"]="墨尔本" ["BOM"]="孟买"
)

declare -A CITY_MAP=(
    ["Hong Kong"]="香港" ["Tokyo"]="东京" ["Singapore"]="新加坡"
    ["Seoul"]="首尔" ["Taipei"]="台北" ["Los Angeles"]="洛杉矶"
    ["San Jose"]="圣何塞" ["Seattle"]="西雅图" ["New York"]="纽约"
    ["London"]="伦敦" ["Frankfurt"]="法兰克福" ["Sydney"]="悉尼"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${@:2}" | tee -a "$LOG_FILE"; }
log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_ok() { log "OK" "$@"; }

enable_direct() {
    log_info "启用直连模式..."
    nft insert rule inet fw4 openclash_mangle_output counter return 2>/dev/null || true
    nft insert rule inet fw4 openclash_mangle counter return 2>/dev/null || true
    sleep 1
}

disable_direct() {
    log_info "恢复代理模式..."
    for chain in openclash_mangle_output openclash_mangle; do
        handle=$(nft -a list chain inet fw4 $chain 2>/dev/null | grep "counter packets" | grep "return" | head -1 | grep -oE 'handle [0-9]+' | awk '{print $2}')
        [ -n "$handle" ] && nft delete rule inet fw4 $chain handle $handle 2>/dev/null || true
    done
}

trap disable_direct EXIT

fetch_ip_sources() {
    log_info "开始获取 IP 源..."
    > raw_input.txt
    for url in "${IP_SOURCES[@]}"; do
        log_info "  获取: $url"
        curl -sL --connect-timeout 10 -m 30 "$url" >> raw_input.txt 2>/dev/null && log_ok "  ✓ 成功" || log_warn "  ✗ 失败"
    done
    log_info "原始数据: $(wc -l < raw_input.txt) 行"
}

clean_ips() {
    log_info "开始清洗 IP..."
    grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' raw_input.txt | \
        awk -F. '$1>=1 && $1<=255 && $2<=255 && $3<=255 && $4<=255 && $1!~/^0/' | \
        sort -u > input.txt
    local count=$(wc -l < input.txt)
    log_info "清洗后有效 IP: $count 个"
    if [ "$count" -eq 0 ]; then
        log_error "没有有效 IP"
        exit 1
    fi
}

test_latency() {
    log_info "开始延迟测试 (阈值: ${LATENCY_LIMIT}ms)..."
    if [ ! -x "$CFST_BIN" ]; then
        log_error "CloudflareST 不存在"
        exit 1
    fi
    $CFST_BIN -f input.txt -dd -tl "$LATENCY_LIMIT" -dn 500 -o tested.csv 2>&1 | tee -a "$LOG_FILE"
    if [ ! -s tested.csv ]; then
        log_error "延迟测试失败"
        exit 1
    fi
    tail -n +2 tested.csv | cut -d',' -f1 | grep -E '^[0-9]' > passed_ips.txt || true
    local count=$(wc -l < passed_ips.txt)
    log_info "通过延迟测试: $count 个"
    if [ "$count" -eq 0 ]; then
        log_error "没有 IP 通过测试"
        exit 1
    fi
}

# 混合方案：先 CF trace，失败用 ip-api
get_location() {
    local ip=$1 colo="" city=""
    
    # 方法1: CF trace
    colo=$(curl -s --connect-timeout 2 -m 3 -k \
           --resolve "speed.cloudflare.com:443:$ip" \
           "https://speed.cloudflare.com/cdn-cgi/trace" 2>/dev/null \
           | grep -oE 'colo=[A-Z]+' | cut -d= -f2)
    
    if [ -n "$colo" ]; then
        echo "${COLO_MAP[$colo]:-$colo}"
        return
    fi
    
    # 方法2: ip-api.com
    city=$(curl -s --connect-timeout 2 -m 3 "http://ip-api.com/json/${ip}?fields=city" 2>/dev/null \
           | grep -oE '"city":"[^"]+"' | cut -d'"' -f4)
    
    if [ -n "$city" ]; then
        echo "${CITY_MAP[$city]:-$city}"
        return
    fi
    
    echo "UNKNOWN"
}

identify_locations() {
    log_info "开始识别地区..."
    > "$OUTPUT_FILE"
    local total=$(wc -l < passed_ips.txt) current=0 success=0
    while IFS= read -r ip; do
        ((current++)) || true
        local loc=$(get_location "$ip")
        if [ "$loc" != "UNKNOWN" ] && [ -n "$loc" ]; then
            echo "${ip}#${loc}" >> "$OUTPUT_FILE"
            ((success++)) || true
            log_info "  [$current/$total] $ip -> $loc"
        else
            log_warn "  [$current/$total] $ip -> UNKNOWN"
        fi
    done < passed_ips.txt
    log_info "识别完成: 成功 $success"
}

git_push() {
    log_info "开始 Git 推送..."
    git config --local user.email "$GIT_EMAIL"
    git config --local user.name "$GIT_NAME"
    git add -A
    if git diff --cached --quiet; then
        log_info "无变化，跳过推送"
        return 0
    fi
    git commit -m "更新优选 IP - $(date '+%Y-%m-%d %H:%M')"
    for i in 1 2 3; do
        if git push origin main 2>&1 | tee -a "$LOG_FILE"; then
            log_ok "推送成功"
            return 0
        fi
        log_warn "推送失败，重试 $i/3..."; sleep 5
    done
    log_error "推送失败"
    return 1
}

main() {
    cd "$WORK_DIR" || { log_error "无法进入 $WORK_DIR"; exit 1; }
    log_info "========== 开始执行 v3.3 =========="
    
    fetch_ip_sources
    clean_ips
    
    enable_direct
    test_latency
    identify_locations
    disable_direct
    
    git_push
    
    log_ok "========== 执行完成 =========="
    log_info "结果: $(wc -l < "$OUTPUT_FILE") 个 IP"
}

main "$@"
