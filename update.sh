#!/bin/bash
# Cloudflare 优选 IP 自动化脚本 v8.3
# 新增特性：VIP 源 (ip.164746.xyz) 结果单独输出到 vip.txt

set -uo pipefail

# 基础配置
WORK_DIR="/root/cfip"
CFST_BIN="./CloudflareST"
LATENCY_LIMIT=200
OUTPUT_FILE="result.txt"
VIP_OUTPUT_FILE="vip.txt"
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

# 1. 下载
fetch_ip_sources() {
    log_info "第1步: 下载 IP 源..."
    
    log_info "  获取 VIP: $VIP_SOURCE"
    curl -sL --connect-timeout 8 -m 20 "$VIP_SOURCE" > raw_vip.txt 2>/dev/null && log_ok "  ✓ 成功" || log_warn "  ✗ 失败"
    
    > raw_normal.txt
    for url in "${NORMAL_SOURCES[@]}"; do
        log_info "  获取: $url"
        curl -sL --connect-timeout 8 -m 20 "$url" >> raw_normal.txt 2>/dev/null && log_ok "  ✓ 成功" || log_warn "  ✗ 失败"
    done
    
    clean_file() {
        grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$1" | \
        awk -F. '$1>=1 && $1<=255 && $2<=255 && $3<=255 && $4<=255 && $1!~/^0/' | \
        sort -u > "$2"
    }

    clean_file raw_vip.txt vip_input.txt
    clean_file raw_normal.txt normal_input.txt
    
    log_info "VIP IP: $(wc -l < vip_input.txt) | 普通 IP: $(wc -l < normal_input.txt)"
}

# 2. 测速 & 识别
test_and_identify() {
    log_info "第2步: 直连双轨测速 & 识别..."
    [ ! -x "$CFST_BIN" ] && { log_error "CloudflareST 不存在"; exit 1; }
    
    # 启用直连
    log_info "  > 启用直连规则"
    nft insert rule inet fw4 openclash_mangle_output counter return comment "CFIP_DIRECT" 2>/dev/null
    sleep 2
    
    # A. 测速
    if [ -s vip_input.txt ]; then
        log_info "  验证 VIP IP (宽松模式)..."
        $CFST_BIN -f vip_input.txt -tl 9999 -dd -dn 0 -o tested_vip.csv 2>&1 >/dev/null
    fi
    
    if [ -s normal_input.txt ]; then
        log_info "  筛选普通 IP (阈值: ${LATENCY_LIMIT}ms)..."
        $CFST_BIN -f normal_input.txt -tl "$LATENCY_LIMIT" -dd -dn 1000 -o tested_normal.csv 2>&1 >/dev/null
    fi
    
    # B. 合并
    > passed_ips.txt
    [ -s tested_vip.csv ] && tail -n +2 tested_vip.csv | cut -d',' -f1 | grep -E '^[0-9]' >> passed_ips.txt
    [ -s tested_normal.csv ] && tail -n +2 tested_normal.csv | cut -d',' -f1 | grep -E '^[0-9]' >> passed_ips.txt
    sort -u passed_ips.txt -o passed_ips.txt
    
    total=$(wc -l < passed_ips.txt)
    log_info "  待识别 IP: $total 个"
    
    # C. 准备 VIP 快速查找表
    declare -A VIP_MAP
    if [ -s vip_input.txt ]; then
        while IFS= read -r vip_ip; do
            VIP_MAP["$vip_ip"]=1
        done < vip_input.txt
    fi

    # D. 识别 COLO
    log_info "  正在识别 COLO (HTTP 直连)..."
    > "$OUTPUT_FILE"
    > "$VIP_OUTPUT_FILE"
    
    if [ "$total" -gt 0 ]; then
        local current=0 success=0
        while IFS= read -r ip; do
            ((current++))
            colo=$(curl -s --connect-timeout 2 -m 3 "http://$ip/cdn-cgi/trace" | grep "colo=" | cut -d= -f2)
            
            if [ -n "$colo" ]; then
                cn_name="${COLO_MAP[$colo]:-$colo}"
                line="${ip}#${cn_name}"
                
                # 写入主文件
                echo "$line" >> "$OUTPUT_FILE"
                
                # 如果是 VIP，额外写入 VIP 文件
                if [ "${VIP_MAP[$ip]+isset}" ]; then
                    echo "$line" >> "$VIP_OUTPUT_FILE"
                fi
                
                ((success++))
            else
                echo "${ip}#UNKNOWN" >> "$OUTPUT_FILE"
                if [ "${VIP_MAP[$ip]+isset}" ]; then
                    echo "${ip}#UNKNOWN" >> "$VIP_OUTPUT_FILE"
                fi
            fi
            
            [ $((current % 10)) -eq 0 ] && echo -ne "  进度: $current/$total (成功: $success)\r"
        done < passed_ips.txt
        echo ""
        log_info "识别完成: $success/$total"
        log_info "VIP 专属结果: $(wc -l < "$VIP_OUTPUT_FILE") 个"
    else
        log_error "没有可用 IP"
    fi

    log_info "  < 恢复代理模式"
    handle=$(nft -a list chain inet fw4 openclash_mangle_output 2>/dev/null | grep 'comment "CFIP_DIRECT"' | head -1 | sed -n 's/.*handle \([0-9]*\).*/\1/p')
    [ -n "$handle" ] && nft delete rule inet fw4 openclash_mangle_output handle $handle 2>/dev/null
}

# 3. 推送
git_push() {
    log_info "第3步: Git 推送..."
    git config --local --unset http.proxy 2>/dev/null || true
    git config --local --unset https.proxy 2>/dev/null || true
    git config --local user.email "$GIT_EMAIL"
    git config --local user.name "$GIT_NAME"
    
    git add -A
    # 如果没有文件变化，git commit 会失败，加个判断
    if git diff --cached --quiet; then
        log_info "无变化，跳过"
    else
        git commit -m "更新优选 IP - $(date '+%Y-%m-%d %H:%M')"
        for i in {1..10}; do
            if git push origin main 2>&1 >/dev/null; then
                log_ok "推送成功"
                return 0
            fi
            log_warn "推送失败，重试 ($i/10)..."
            sleep 5
        done
        log_error "推送失败"
    fi
}

main() {
    cd "$WORK_DIR" || exit 1
    log_info "========== v8.3 VIP独立输出版 =========="
    cleanup_env
    fetch_ip_sources
    test_and_identify
    git_push
    log_ok "========== 完成 =========="
    log_info "总结果: $(wc -l < "$OUTPUT_FILE") 个 | VIP结果: $(wc -l < "$VIP_OUTPUT_FILE") 个"
}

main "$@"
