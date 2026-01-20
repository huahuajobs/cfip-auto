#!/bin/bash
# Cloudflare 优选 IP 自动化脚本 v8.1
# 修复：Git 推送跟随系统代理，取消强制指定端口；增加重试次数

set -uo pipefail

# 基础配置
WORK_DIR="/root/cfip"
CFST_BIN="./CloudflareST"
LATENCY_LIMIT=200
OUTPUT_FILE="result.txt"
LOG_FILE="update.log"
GIT_EMAIL="cfip@router.local"
GIT_NAME="CFIP Bot"

# 地区映射
declare -A COLO_MAP=(
    ["HKG"]="香港" ["NRT"]="日本东京" ["KIX"]="日本大阪" ["ICN"]="韩国首尔"
    ["SIN"]="新加坡" ["TPE"]="台湾台北" ["KHH"]="台湾高雄" ["BKK"]="泰国曼谷"
    ["SYD"]="澳大利亚悉尼" ["LAX"]="美国洛杉矶" ["SJC"]="美国圣何塞" ["SEA"]="美国西雅图"
    ["IAD"]="美国华盛顿" ["ORD"]="美国芝加哥" ["DFW"]="美国达拉斯" ["ATL"]="美国亚特兰大"
    ["MIA"]="美国迈阿密" ["EWR"]="美国纽瓦克" ["FRA"]="德国法兰克福" ["LHR"]="英国伦敦"
    ["CDG"]="法国巴黎" ["AMS"]="荷兰阿姆斯特丹" ["MAD"]="西班牙马德里"
)

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

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${@:2}" | tee -a "$LOG_FILE"; }
log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_ok() { log "OK" "$@"; }
log_error() { log "ERROR" "$@"; }

# 0. 环境清理
cleanup_env() {
    log_info "初始化环境..."
    while true; do
        handle=$(nft -a list chain inet fw4 openclash_mangle_output 2>/dev/null | grep 'comment "CFIP_DIRECT"' | head -1 | sed -n 's/.*handle \([0-9]*\).*/\1/p')
        [ -z "$handle" ] && break
        log_warn "删除残留规则 handle: $handle"
        nft delete rule inet fw4 openclash_mangle_output handle $handle 2>/dev/null
    done
}

# 1. 代理模式下载
fetch_ip_sources() {
    log_info "第1步: 下载 IP 源..."
    > raw_input.txt
    for url in "${IP_SOURCES[@]}"; do
        log_info "  获取: $url"
        # 使用系统默认代理 (同 curl 默认行为)
        curl -sL --connect-timeout 8 -m 20 "$url" >> raw_input.txt 2>/dev/null && log_ok "  ✓ 成功" || log_warn "  ✗ 失败"
    done
    
    grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' raw_input.txt | \
        awk -F. '$1>=1 && $1<=255 && $2<=255 && $3<=255 && $4<=255 && $1!~/^0/' | \
        sort -u > input.txt
    log_info "有效 IP 总数: $(wc -l < input.txt)"
}

# 2. 直连模式测试 & 识别
test_and_identify() {
    log_info "第2步: 直连测速 & 识别 (HTTP模式)..."
    [ ! -x "$CFST_BIN" ] && { log_error "CloudflareST 不存在"; exit 1; }
    
    log_info "  > 启用直连规则"
    nft insert rule inet fw4 openclash_mangle_output counter return comment "CFIP_DIRECT" 2>/dev/null
    sleep 2
    
    log_info "  正在测速..."
    $CFST_BIN -f input.txt -tl "$LATENCY_LIMIT" -dd -dn 1000 -o tested.csv 2>&1 | tee -a "$LOG_FILE"
    
    log_info "  正在识别 COLO (HTTP 直连)..."
    > "$OUTPUT_FILE"
    
    if [ -s tested.csv ]; then
        tail -n +2 tested.csv | cut -d',' -f1 | grep -E '^[0-9]' > passed_ips.txt
        local total=$(wc -l < passed_ips.txt)
        local current=0 success=0
        
        while IFS= read -r ip; do
            ((current++))
            colo=$(curl -s --connect-timeout 2 -m 3 "http://$ip/cdn-cgi/trace" | grep "colo=" | cut -d= -f2)
            
            if [ -n "$colo" ]; then
                cn_name="${COLO_MAP[$colo]:-$colo}"
                echo "${ip}#${cn_name}" >> "$OUTPUT_FILE"
                ((success++))
            else
                echo "${ip}#UNKNOWN" >> "$OUTPUT_FILE"
            fi
            
            [ $((current % 10)) -eq 0 ] && echo -ne "  进度: $current/$total (成功: $success)\r"
            
        done < passed_ips.txt
        echo ""
        log_info "识别完成: $success/$total"
    else
        log_error "没有 IP 通过延迟测试"
    fi

    log_info "  < 恢复代理模式"
    handle=$(nft -a list chain inet fw4 openclash_mangle_output 2>/dev/null | grep 'comment "CFIP_DIRECT"' | head -1 | sed -n 's/.*handle \([0-9]*\).*/\1/p')
    [ -n "$handle" ] && nft delete rule inet fw4 openclash_mangle_output handle $handle 2>/dev/null
}

# 3. 推送 (跟随系统代理)
git_push() {
    [ ! -s "$OUTPUT_FILE" ] && return 0
    log_info "第3步: Git 推送..."
    
    # 清除本地可能错误的代理配置，让 Git 使用系统环境变量
    git config --local --unset http.proxy 2>/dev/null || true
    git config --local --unset https.proxy 2>/dev/null || true
    
    git config --local user.email "$GIT_EMAIL"
    git config --local user.name "$GIT_NAME"
    
    git add -A
    git diff --cached --quiet && { log_info "无变化，跳过"; return 0; }
    git commit -m "更新优选 IP - $(date '+%Y-%m-%d %H:%M')"
    
    # 重试 10 次
    for i in {1..10}; do
        # 尝试推送。如果失败，输出错误并重试
        if git push origin main 2>&1; then
            log_ok "推送成功"
            return 0
        fi
        log_warn "推送失败，5秒后重试 ($i/10)..."
        sleep 5
    done
    log_error "推送最终失败，请检查网络或 Git 配置"
}

main() {
    cd "$WORK_DIR" || exit 1
    log_info "========== v8.1 系统代理版 =========="
    cleanup_env
    fetch_ip_sources
    test_and_identify
    git_push
    log_ok "========== 完成 =========="
    log_info "结果: $(wc -l < "$OUTPUT_FILE") 个"
}

main "$@"
