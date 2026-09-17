#!/bin/bash
set -e
# ============================================================
# CFST 优选 IP + Cloudflare DDNS + Worker 上传脚本
# Version: v5.0
# 功能：自动测速 Cloudflare 优选 IP → 更新 DNS → 上传结果到 Worker
# ============================================================

# ==================== 基础配置 ====================
# Cloudflare API 相关（请填写真实值）
API_TOKEN=""    # Cloudflare API Token（需要 Zone:DNS:Edit 权限）
ZONE_ID=""  # 域名所在 Zone ID
RECORD_NAME=""  # 要更新的 DNS 记录名称（如 cf.example.com）

# 测速相关
CUSTOM_SPEED_URL="https://filedownload.helo.de5.net"    # 自定义测速下载地址

# 上传接口相关
UPLOAD_URL="https://cfbestip.cfworkers.com/api/upload"    # Worker 上传接口地址
AUTH_KEY="BUldfsdfsflKr484" # 上传接口 Authorization 密钥

# 运营商标识
# ct = 电信
# cu = 联通
# cm = 移动
# default = 未识别
CARRIER="default"

# Telegram 通知相关（上传接口需要这两个字段）
TG_BOT_TOKEN="" # Telegram Bot Token
TG_CHAT_ID=""   # Telegram ID

# 最大运行时间保护（秒），超时强制退出，防止卡死
MAX_RUNTIME=1800   # 30 分钟

# ==================== 路径配置 ====================
BASE_DIR=$(cd "$(dirname "$0")" && pwd)                # 脚本所在目录
CFST_BIN="$BASE_DIR/cfst"                              # CFST 可执行文件路径
RESULT_FILE="$BASE_DIR/result.csv"                     # 测速结果 CSV 文件
LOG_DIR="$BASE_DIR/logs"                               # 日志目录
mkdir -p "$LOG_DIR"                                    # 确保日志目录存在
LOG_FILE="$LOG_DIR/cfst_ddns_$(date '+%F').log"        # 当天日志文件

# ==================== 日志函数 ====================
# 写日志并同时输出到终端
# 参数1: 日志级别 (INFO/WARN/ERROR)
# 参数2: 日志内容
log() {
    echo "[$(date '+%F %T')] [PID:$$] [$1] $2" | tee -a "$LOG_FILE"
}

# 清理 7 天前的旧日志
clean_logs() {
    find "$LOG_DIR" -type f -name "cfst_ddns_*.log" -mtime +7 -delete
}

# ============================================================
# 自动检测当前公网线路运营商
# ============================================================
detect_carrier() {
    log INFO "开始检测当前网络线路..."

    local GEO_JSON
    local ISP
    local GEO_IP

    GEO_JSON=$(curl -s \
        --connect-timeout 10 \
        --max-time 15 \
        "http://ip-api.com/json/?fields=query,isp" \
        2>/dev/null || true)

    if [[ -z "$GEO_JSON" ]]; then
        CARRIER="default"
        log WARN "线路检测失败，按 default 处理"
        return 0
    fi

    ISP=$(echo "$GEO_JSON" | jq -r '.isp // empty' 2>/dev/null || true)
    GEO_IP=$(echo "$GEO_JSON" | jq -r '.query // empty' 2>/dev/null || true)

    if [[ -z "$ISP" ]]; then
        CARRIER="default"
        log WARN "无法获取 ISP 信息，按 default 处理"
        return 0
    fi

    if echo "$ISP" | grep -Eiq 'China Mobile|移动'; then
        CARRIER="cm"
        log INFO "当前公网 IP : ${GEO_IP:-未知}"
        log INFO "当前 ISP     : $ISP"
        log INFO "检测到运营商 : 中国移动 (cm)"

    elif echo "$ISP" | grep -Eiq 'China Unicom|联通'; then
        CARRIER="cu"
        log INFO "当前公网 IP : ${GEO_IP:-未知}"
        log INFO "当前 ISP     : $ISP"
        log INFO "检测到运营商 : 中国联通 (cu)"

    elif echo "$ISP" | grep -Eiq 'China Telecom|电信'; then
        CARRIER="ct"
        log INFO "当前公网 IP : ${GEO_IP:-未知}"
        log INFO "当前 ISP     : $ISP"
        log INFO "检测到运营商 : 中国电信 (ct)"

    else
        CARRIER="default"
        log WARN "当前公网 IP : ${GEO_IP:-未知}"
        log WARN "当前 ISP     : $ISP"
        log WARN "未识别到移动/联通/电信，使用 default"
        log WARN "如果当前使用了代理/TUN/全局模式，测速结果可能是代理出口视角"
    fi
}

# ==================== 进程锁（防止重复运行） ====================
LOCK_FILE="/tmp/cfst_ddns.lock"

# 获取文件锁，如果已有进程在运行则直接退出
lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log WARN "已有任务正在运行，本次退出"
        exit 0
    fi
    echo $$ >&200
    log INFO "进程锁获取成功"
}

# 释放文件锁
unlock() {
    flock -u 200 || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

# 脚本退出时自动释放锁
trap unlock EXIT

# ==================== 超时看门狗 ====================
WATCHDOG_PID=""

# 启动超时保护（超过 MAX_RUNTIME 秒强制杀掉主进程）
start_watchdog() {
    (
        sleep "$MAX_RUNTIME"
        log ERROR "任务运行超过 ${MAX_RUNTIME} 秒，强制退出"
        kill -TERM $$ 2>/dev/null
        sleep 5
        kill -9 $$ 2>/dev/null
    ) &
    WATCHDOG_PID=$!
}

# 停止看门狗
stop_watchdog() {
    [[ -n "$WATCHDOG_PID" ]] && kill "$WATCHDOG_PID" 2>/dev/null || true
}

# ==================== CFST 测速函数 ====================
# 使用 CFST 工具对 Cloudflare IP 进行测速，选出最佳 IP
speed_test() {
    # 默认测速参数
    local n=50          # 延迟测速线程数
    local t=4           # 延迟测速次数
    local dn=10         # 下载测速线程数
    local dt=10         # 下载测速时间（秒）
    local tp=443        # 测速端口
    local tl=160        # 平均延迟上限（ms）
    local tll=20        # 平均延迟下限（ms）
    local tlr=0         # 丢包率上限
    local sl=0.01       # 下载速度下限（MB/s）
    local p=10          # 显示结果数量

    # 获取当前小时（去掉前导零）
    HOUR=$(date +%H | sed 's/^0//')

    # 晚高峰（19:00-23:00）放宽参数，提高成功率
    if (( HOUR >= 19 && HOUR <= 23 )); then
        t=8
        dt=15
        tl=200
        tlr=0.2
    fi

    log INFO "开始 CFST 测速"
    log INFO "参数: n=$n t=$t dn=$dn dt=$dt tl=$tl tlr=$tlr sl=$sl"

    # 清理旧结果文件
    rm -f "$RESULT_FILE"
    cd "$BASE_DIR"

    # 构建 CFST 命令
    CMD=(
        "$CFST_BIN"
        -n  "$n"
        -t  "$t"
        -dn "$dn"
        -dt "$dt"
        -tp "$tp"
        -url "$CUSTOM_SPEED_URL"
        -tl "$tl"
        -tll "$tll"
        -tlr "$tlr"
        -sl "$sl"
        -p  "$p"
        -o  "$RESULT_FILE"
    )

    log INFO "执行 CFST 命令"
    echo "${CMD[*]}" >> "$LOG_FILE"

    # 执行测速（最多等待 15 分钟）
    START=$(date +%s)
    if ! timeout 900 "${CMD[@]}"; then
        log ERROR "CFST 测速失败或超时"
        return 1
    fi
    END=$(date +%s)
    log INFO "CFST 测速完成，耗时 $((END - START)) 秒"

    # 检查结果文件是否生成
    if [[ ! -s "$RESULT_FILE" ]]; then
        log ERROR "测速结果文件为空或不存在"
        return 1
    fi

    # 从 CSV 中提取速度最高的 IP 和对应速度
    # CSV 格式通常为: IP, 已发送, 已接收, 丢包率, 平均延迟, 下载速度(MB/s), 地区...
    read IP SPEED_RAW <<< "$(
        awk -F',' '
            NR > 1 && $6 + 0 > max {
                max = $6
                ip  = $1
            }
            END {
                print ip, max
            }
        ' "$RESULT_FILE"
    )"

    # 提取纯数字速度
    SPEED=$(echo "$SPEED_RAW" | grep -Eo '[0-9]+(\.[0-9]+)?')

    if [[ -z "$IP" || -z "$SPEED" ]]; then
        log ERROR "无法解析有效的测速结果"
        return 1
    fi

    log INFO "最佳 IP : $IP"
    log INFO "下载速度: ${SPEED} MB/s"
}

# ==================== Cloudflare DNS 更新函数 ====================
# 将测速得到的最佳 IP 更新到指定 DNS 记录
update_dns() {
    if [[ -z "$IP" ]]; then
        log ERROR "IP 为空，无法更新 DNS"
        return 1
    fi

    log INFO "开始更新 DNS: $RECORD_NAME → $IP"

    # 1. 查询现有 DNS 记录 ID
    RES=$(curl -s \
        --connect-timeout 10 \
        --max-time 30 \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$RECORD_NAME" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json")

    RECORD_ID=$(echo "$RES" | jq -r '.result[0].id')

    if [[ -z "$RECORD_ID" || "$RECORD_ID" == "null" ]]; then
        log ERROR "获取 DNS 记录 ID 失败"
        log ERROR "$RES"
        return 1
    fi

    # 2. 更新 DNS 记录
    RES=$(curl -s \
        --connect-timeout 10 \
        --max-time 30 \
        -X PUT \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$RECORD_NAME\",\"content\":\"$IP\",\"ttl\":60,\"proxied\":false}")

    if [[ "$RES" == *'"success":true'* ]]; then
        log INFO "DNS 更新成功 → $IP"
    else
        log ERROR "DNS 更新失败"
        log ERROR "$RES"
        return 1
    fi
}

# ==================== 上传结果到 Worker ====================
# Worker /api/upload 要求：
# POST Body 必须直接是 JSON 数组
upload() {
    if [[ ! -f "$RESULT_FILE" ]]; then
        log ERROR "测速结果文件不存在，无法上传"
        return 1
    fi

    log INFO "开始生成上传数据"

    TIME=$(date "+%F %T")
    JSON=()

    # 读取 CSV（跳过表头），构建每个节点的 JSON 对象
    {
        read -r HEADER

        while IFS=, read -r ip sent received loss latency speed region; do

            # 去除前后空格
            ip=$(echo "$ip" | xargs)
            speed=$(echo "$speed" | xargs)
            latency=$(echo "$latency" | xargs)
            region=$(echo "$region" | xargs)

            # 跳过空 IP
            [[ -z "$ip" ]] && continue

            # 使用 jq 安全构建 JSON 对象
            ITEM=$(jq -n \
                --arg ip      "$ip" \
                --arg speed   "$speed" \
                --arg latency "$latency" \
                --arg region  "$region" \
                --arg time    "$TIME" \
                --arg carrier "$CARRIER" \
                '{
                    ip:      $ip,
                    speed:   ($speed | tonumber?),
                    latency: $latency,
                    region:  $region,
                    time:    $time,
                    carrier: $carrier
                }')

            JSON+=("$ITEM")

        done

    } < "$RESULT_FILE"

    # 将所有节点合并成 JSON 数组
    DATA=$(printf '%s\n' "${JSON[@]}" | jq -s '.')

    COUNT=$(echo "$DATA" | jq length)

    log INFO "准备上传节点数量: $COUNT"

    # ========================================================
    # Worker /api/upload 要求：
    # 请求体本身就是 JSON 数组
    # ========================================================
    PAYLOAD="$DATA"

    # 可选：记录实际上传的数据格式
    log INFO "上传数据格式: JSON Array"

    # 发送 POST 请求
    RESPONSE=$(curl -s \
        --connect-timeout 10 \
        --max-time 60 \
        -w "\n%{http_code}" \
        -X POST "$UPLOAD_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: $AUTH_KEY" \
        -d "$PAYLOAD")

    # 分离响应体和 HTTP 状态码
    CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [[ "$CODE" == "200" ]]; then
        log INFO "上传成功"
    else
        log ERROR "上传失败，HTTP 状态码: $CODE"
        log ERROR "$BODY"
        return 1
    fi
}

# ==================== 主流程 ====================
main() {
    # 清理旧日志
    clean_logs

    START=$(date +%s)

    log INFO "========================================"
    log INFO "CFST DDNS 任务启动"
    log INFO "域名   : $RECORD_NAME"
    log INFO "========================================"

    # 获取进程锁
    lock

    # ========================================================
    # 自动检测当前公网线路运营商
    # ========================================================
    detect_carrier

    log INFO "最终运营商标识: $CARRIER"

    # 启动超时看门狗
    start_watchdog

    # 1. CFST 测速
    if ! speed_test; then
        log ERROR "CFST 测速失败，无法继续执行"
        exit 1
    fi

    # ========================================================
    # 2. Cloudflare DNS 更新
    #
    # DNS 更新是独立任务：
    # - 成功：记录成功
    # - 失败：只记录警告，不影响后面的测速结果上传
    # ========================================================
    if update_dns; then
        log INFO "DNS 更新任务完成"
    else
        log WARN "DNS 更新任务失败，但不影响测速结果上传"
    fi

    # ========================================================
    # 3. 上传测速结果
    #
    # 上传任务独立于 DNS：
    # - DNS 成功 → 上传
    # - DNS 失败 → 仍然上传
    # ========================================================
    if upload; then
        log INFO "测速结果上传任务完成"
    else
        log ERROR "测速结果上传任务失败"
        exit 1
    fi

    # 停止看门狗
    stop_watchdog

    END=$(date +%s)

    log INFO "========================================"
    log INFO "任务全部完成"
    log INFO "最佳 IP : $IP"
    log INFO "下载速度: ${SPEED} MB/s"
    log INFO "总耗时  : $((END - START)) 秒"
    log INFO "========================================"
}

# 执行主函数
main
