#!/bin/bash
# Cloudflare 优选 IP 自动化脚本 v2.2

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

# 城市中文名映射
declare -A CITY_MAP=(
    ["Toronto"]="多伦多" ["Los Angeles"]="洛杉矶" ["San Jose"]="圣何塞"
    ["Seattle"]="西雅图" ["Chicago"]="芝加哥" ["Dallas"]="达拉斯"
    ["Miami"]="迈阿密" ["Atlanta"]="亚特兰大" ["New York"]="纽约"
    ["Washington"]="华盛顿" ["Vancouver"]="温哥华"
    ["London"]="伦敦" ["Frankfurt"]="法兰克福" ["Amsterdam"]="阿姆斯特丹"
    ["Paris"]="巴黎" ["Madrid"]="马德里"
    ["Tokyo"]="东京" ["Seoul"]="首尔" ["Singapore"]="新加坡"
    ["Hong Kong"]="香港" ["Taipei"]="台北" ["Sydney"]="悉尼"
    ["San Francisco"]="旧金山" ["Phoenix"]="凤凰城" ["Denver"]="丹佛"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${@:2}" | tee -a "$LOG_FILE"; }
log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_ok() { log "OK" "$@"; }

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

# 使用 ip-api.com 获取城市
get_city() {
    local ip=$1
    local city=""
    city=$(curl -s --connect-timeout 3 -m 5 "http://ip-api.com/json/${ip}?fields=city" 2>/dev/null | \
           grep -oE '"city":"[^"]+"' | cut -d'"' -f4)
    echo "${city:-UNKNOWN}"
}

identify_locations() {
    log_info "开始识别地区..."
    > "$OUTPUT_FILE"
    local total=$(wc -l < passed_ips.txt) current=0 success=0
    while IFS= read -r ip; do
        ((current++)) || true
        local city=$(get_city "$ip")
        local city_cn="${CITY_MAP[$city]:-$city}"
        if [ "$city" != "UNKNOWN" ] && [ -n "$city" ]; then
            echo "${ip}#${city_cn}" >> "$OUTPUT_FILE"
            ((success++)) || true
            log_info "  [$current/$total] $ip -> $city_cn"
        else
            log_warn "  [$current/$total] $ip -> UNKNOWN"
        fi
        # ip-api.com 免费版限速：45次/分钟，添加延迟
        sleep 1.5
    done < passed_ips.txt
    log_info "地区识别完成: 成功 $success"
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
    log_info "========== 开始执行 =========="
    fetch_ip_sources
    clean_ips
    test_latency
    identify_locations
    git_push
    log_ok "========== 执行完成 =========="
    log_info "结果: $(wc -l < "$OUTPUT_FILE") 个 IP"
}

main "$@"
