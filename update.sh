#!/bin/bash
# Cloudflare 优选 IP 自动化脚本 v7.1 (安全修复版)
# 修复：使用 comment 标记精确管理规则，防止误删系统规则

set -uo pipefail

# 基础配置
WORK_DIR="/root/cfip"
CFST_BIN="./CloudflareST"
LATENCY_LIMIT=200
OUTPUT_FILE="result.txt"
LOG_FILE="update.log"
GIT_EMAIL="cfip@router.local"
GIT_NAME="CFIP Bot"

# IP 源
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

# 地区映射
declare -A COLO_MAP=(
    ["HKG"]="香港" ["NRT"]="日本东京" ["KIX"]="日本大阪" ["ICN"]="韩国首尔"
    ["SIN"]="新加坡" ["TPE"]="台湾台北" ["KHH"]="台湾高雄" ["BKK"]="泰国曼谷"
    ["SYD"]="澳大利亚悉尼" ["LAX"]="美国洛杉矶" ["SJC"]="美国圣何塞" ["SEA"]="美国西雅图"
    ["IAD"]="美国华盛顿" ["ORD"]="美国芝加哥" ["DFW"]="美国达拉斯" ["ATL"]="美国亚特兰大"
    ["MIA"]="美国迈阿密" ["EWR"]="美国纽瓦克" ["FRA"]="德国法兰克福" ["LHR"]="英国伦敦"
    ["CDG"]="法国巴黎" ["AMS"]="荷兰阿姆斯特丹" ["MAD"]="西班牙马德里"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${@:2}" | tee -a "$LOG_FILE"; }
log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_ok() { log "OK" "$@"; }
log_error() { log "ERROR" "$@"; }

# 0. 环境清理 (安全版)
cleanup_env() {
    log_info "初始化环境..."
    # 精确匹配带有 CFIP_DIRECT 注释的规则
    while true; do
        handle=$(nft -a list chain inet fw4 openclash_mangle_output 2>/dev/null | grep 'comment "CFIP_DIRECT"' | head -1 | sed -n 's/.*handle \([0-9]*\).*/\1/p')
        [ -z "$handle" ] && break
        log_warn "删除 CFIP 直连规则 handle: $handle"
        nft delete rule inet fw4 openclash_mangle_output handle $handle 2>/dev/null
    done
}

# 1. 代理模式下载 IP 源
fetch_ip_sources() {
    log_info "第1步: 下载 IP 源 (代理模式)..."
    > raw_input.txt
    for url in "${IP_SOURCES[@]}"; do
        log_info "  获取: $url"
        curl -sL --connect-timeout 8 -m 20 "$url" >> raw_input.txt 2>/dev/null && log_ok "  ✓ 成功" || log_warn "  ✗ 失败"
    done
    
    grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' raw_input.txt | \
        awk -F. '$1>=1 && $1<=255 && $2<=255 && $3<=255 && $4<=255 && $1!~/^0/' | \
        sort -u > input.txt
        
    local count=$(wc -l < input.txt)
    log_info "有效 IP 总数: $count"
    [ "$count" -eq 0 ] && { log_error "没有有效 IP"; exit 1; }
}

# 2. 直连模式测试真实延迟
test_latency_real() {
    log_info "第2步: 测试真实延迟 (直连模式)..."
    [ ! -x "$CFST_BIN" ] && { log_error "CloudflareST 不存在"; exit 1; }
    
    # 启用直连规则 (带注释标记)
    log_info "  > 启用直连规则"
    nft insert rule inet fw4 openclash_mangle_output counter return comment "CFIP_DIRECT" 2>/dev/null
    sleep 2
    
    # -dd 禁用下载测速
    $CFST_BIN -f input.txt -tl "$LATENCY_LIMIT" -dd -dn 1000 -o tested.csv 2>&1 | tee -a "$LOG_FILE"
    
    # 删除规则 (带注释标记)
    log_info "  < 恢复代理模式"
    handle=$(nft -a list chain inet fw4 openclash_mangle_output 2>/dev/null | grep 'comment "CFIP_DIRECT"' | head -1 | sed -n 's/.*handle \([0-9]*\).*/\1/p')
    [ -n "$handle" ] && nft delete rule inet fw4 openclash_mangle_output handle $handle 2>/dev/null
    sleep 2
    
    if [ -s tested.csv ]; then
        tail -n +2 tested.csv | cut -d',' -f1 | grep -E '^[0-9]' > passed_ips.txt
        local count=$(wc -l < passed_ips.txt)
        log_info "真实延迟 <${LATENCY_LIMIT}ms IP: $count 个"
        [ "$count" -eq 0 ] && { log_error "没有 IP 通过延迟测试"; exit 1; }
    else
        log_error "测试结果为空"
        exit 1
    fi
}

# 3. 代理模式识别 COLO
identify_colo_proxy() {
    log_info "第3步: 识别 COLO (代理反向筛选)..."
    > "$OUTPUT_FILE"
    local total_identified=0
    cp passed_ips.txt remaining_ips.txt
    
    for colo in "${!COLO_MAP[@]}"; do
        local cn_name="${COLO_MAP[$colo]}"
        [ ! -s remaining_ips.txt ] && break
        
        temp_csv="temp_${colo}.csv"
        $CFST_BIN -f remaining_ips.txt -httping -cfcolo "$colo" -tl 9999 -dd -dn 0 -o "$temp_csv" >/dev/null 2>&1
        
        if [ -s "$temp_csv" ]; then
            local matched_ips=$(tail -n +2 "$temp_csv" | cut -d',' -f1 | grep -E '^[0-9]')
            if [ -n "$matched_ips" ]; then
                local num=$(echo "$matched_ips" | wc -l)
                while IFS= read -r ip; do
                    echo "${ip}#${cn_name}" >> "$OUTPUT_FILE"
                done <<< "$matched_ips"
                ((total_identified+=num))
                grep -vFf <(echo "$matched_ips") remaining_ips.txt > remaining_ips.tmp && mv remaining_ips.tmp remaining_ips.txt
            fi
        fi
        rm -f "$temp_csv"
    done
    
    if [ -s remaining_ips.txt ]; then
        local unknown_count=$(wc -l < remaining_ips.txt)
        log_warn "  未识别地区: $unknown_count 个"
        while IFS= read -r ip; do
             echo "${ip}#UNKNOWN" >> "$OUTPUT_FILE"
        done < remaining_ips.txt
    fi
    log_info "识别完成: 总计 $total_identified 个已知地区"
}

# 4. 推送
git_push() {
    [ ! -s "$OUTPUT_FILE" ] && return 0
    log_info "第4步: Git 推送..."
    git config --local user.email "$GIT_EMAIL"
    git config --local user.name "$GIT_NAME"
    git add -A
    git diff --cached --quiet && { log_info "无变化，跳过"; return 0; }
    git commit -m "更新优选 IP - $(date '+%Y-%m-%d %H:%M')"
    for i in 1 2 3; do
        git push origin main 2>&1 >/dev/null && { log_ok "推送成功"; return 0; }
        sleep 5
    done
    log_error "推送失败"
}

main() {
    cd "$WORK_DIR" || exit 1
    log_info "========== 开始执行 v7.1 (安全版) =========="
    cleanup_env
    fetch_ip_sources
    test_latency_real
    identify_colo_proxy
    git_push
    log_ok "========== 全部完成 =========="
    log_info "结果保存在: $OUTPUT_FILE ($(wc -l < "$OUTPUT_FILE") 行)"
}

main "$@"
