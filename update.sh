#!/bin/bash
# Cloudflare 优选 IP 自动化脚本 v5.0
# 使用 cf-ray 响应头获取 COLO（代理模式可用）

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
    ["HKG"]="香港" ["NRT"]="日本东京" ["KIX"]="日本大阪" ["ICN"]="韩国首尔"
    ["SIN"]="新加坡" ["TPE"]="台湾台北" ["LAX"]="美国洛杉矶" ["SJC"]="美国圣何塞"
    ["SEA"]="美国西雅图" ["IAD"]="美国华盛顿" ["ORD"]="美国芝加哥" ["DFW"]="美国达拉斯"
    ["FRA"]="德国法兰克福" ["LHR"]="英国伦敦" ["CDG"]="法国巴黎" ["AMS"]="荷兰阿姆斯特丹"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${@:2}" | tee -a "$LOG_FILE"; }
log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_ok() { log "OK" "$@"; }
log_error() { log "ERROR" "$@"; }

DIRECT_HANDLE=""
enable_direct() {
    log_info "启用直连模式..."
    nft insert rule inet fw4 openclash_mangle_output counter return
    sleep 1
    DIRECT_HANDLE=$(nft -a list chain inet fw4 openclash_mangle_output | head -5 | grep "counter packets" | grep " return$" | head -1 | grep -oE 'handle [0-9]+' | awk '{print $2}')
    log_info "直连规则 handle: $DIRECT_HANDLE"
}

disable_direct() {
    log_info "恢复代理模式..."
    [ -n "$DIRECT_HANDLE" ] && nft delete rule inet fw4 openclash_mangle_output handle $DIRECT_HANDLE 2>/dev/null
    sleep 2
    log_ok "代理已恢复"
}

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
    log_info "清洗后有效 IP: $(wc -l < input.txt) 个"
    [ $(wc -l < input.txt) -eq 0 ] && { log_error "没有有效 IP"; exit 1; }
}

test_latency() {
    log_info "开始延迟测试 (HTTPing, 阈值: ${LATENCY_LIMIT}ms)..."
    [ ! -x "$CFST_BIN" ] && { log_error "CloudflareST 不存在"; exit 1; }
    $CFST_BIN -f input.txt -httping -tl "$LATENCY_LIMIT" -dd -dn 500 -o tested.csv 2>&1 | tee -a "$LOG_FILE"
    [ ! -s tested.csv ] && { log_error "延迟测试失败"; exit 1; }
    tail -n +2 tested.csv | cut -d',' -f1 | grep -E '^[0-9]' > passed_ips.txt || true
    log_info "通过延迟测试: $(wc -l < passed_ips.txt) 个"
    [ $(wc -l < passed_ips.txt) -eq 0 ] && { log_error "没有 IP 通过测试"; exit 1; }
}

# 使用 cf-ray 响应头获取 COLO
get_colo() {
    local ip=$1
    local colo=$(curl -sI --connect-timeout 2 -m 3 --resolve "cloudflare.com:443:$ip" "https://cloudflare.com" 2>/dev/null | grep -i "cf-ray" | grep -oE '[A-Z]{3}$')
    echo "${colo:-UNKNOWN}"
}

identify_colo() {
    log_info "开始识别 COLO (cf-ray 方式)..."
    > "$OUTPUT_FILE"
    local total=$(wc -l < passed_ips.txt) current=0 success=0
    while IFS= read -r ip; do
        ((current++)) || true
        local colo=$(get_colo "$ip")
        if [ "$colo" != "UNKNOWN" ] && [ -n "$colo" ]; then
            local cn_name="${COLO_MAP[$colo]:-$colo}"
            echo "${ip}#${cn_name}" >> "$OUTPUT_FILE"
            ((success++)) || true
            log_info "  [$current/$total] $ip -> $colo ($cn_name)"
        else
            log_warn "  [$current/$total] $ip -> UNKNOWN"
        fi
    done < passed_ips.txt
    log_info "COLO 识别完成: 成功 $success"
}

git_push() {
    log_info "开始 Git 推送..."
    git config --local user.email "$GIT_EMAIL"
    git config --local user.name "$GIT_NAME"
    git add -A
    git diff --cached --quiet && { log_info "无变化，跳过推送"; return 0; }
    git commit -m "更新优选 IP - $(date '+%Y-%m-%d %H:%M')"
    for i in 1 2 3; do
        git push origin main 2>&1 | tee -a "$LOG_FILE" && { log_ok "推送成功"; return 0; }
        log_warn "推送失败，重试 $i/3..."; sleep 5
    done
    log_error "推送失败"; return 1
}

main() {
    cd "$WORK_DIR" || { log_error "无法进入 $WORK_DIR"; exit 1; }
    log_info "========== 开始执行 v5.0 =========="
    
    fetch_ip_sources
    clean_ips
    
    enable_direct
    test_latency
    disable_direct
    
    identify_colo  # 代理模式下用 cf-ray 获取 COLO
    git_push
    
    log_ok "========== 执行完成 =========="
    log_info "结果: $(wc -l < "$OUTPUT_FILE") 个 IP"
}

main "$@"
