#!/bin/bash
set -e

# ============================================================
# CFST 优选 IP + Cloudflare DDNS + Worker 上传脚本
# EdgeRouter X / EdgeOS 适配版
# Version: v5.0-ERX
#
# 功能：
#   自动测速 Cloudflare 优选 IP
#   更新 Cloudflare DNS
#   上传测速结果到 Worker
#
# 适配：
#   EdgeRouter X
#   EdgeOS
#   MIPSel CFST
#
# 重要：
#   请确认 CFST 二进制文件为 MIPSel 版本
#   请确认 curl 为 MIPSel MUSL 版本
# ============================================================


# ==================== 基础配置 ====================

# Cloudflare API 相关
# 请填写真实值

API_TOKEN=""       # Cloudflare API Token，需要 Zone:DNS:Edit 权限
ZONE_ID=""         # 域名所在 Zone ID
RECORD_NAME=""     # 要更新的 DNS 记录名称，例如 cf.example.com


# ==================== 测速相关 ====================

CUSTOM_SPEED_URL="https://filedownload.helo.de5.net"


# ==================== 上传接口相关 ====================

UPLOAD_URL="https://cfbestip.cfworkers.com/api/upload"

AUTH_KEY="BUllddsfffslKr484"

# 运营商标识
# ct = 电信
# cu = 联通
# cm = 移动

#CARRIER="cu"
CARRIER="default"
# ============================================================
# 自动检测当前公网线路运营商
# ============================================================
detect_carrier() {
    log INFO "开始检测当前网络线路..."

    local GEO_JSON
    local ISP
    local GEO_IP

    GEO_JSON=$("$CURL_BIN" -s \
        --max-time 10 \
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


# ==================== Telegram 相关 ====================

# 注意：
# 你的 Worker 上传接口会根据实际配置处理 Telegram 通知。
# 这里保留原配置，但当前脚本不直接发送 Telegram。

TG_BOT_TOKEN=""
TG_CHAT_ID=""


# ==================== 运行保护 ====================

# 最大运行时间：30 分钟

MAX_RUNTIME=1800


# ==================== 路径配置 ====================

# ER-X 固定目录
BASE_DIR="/config/cfst"

# CFST 可执行文件
CFST_BIN="$BASE_DIR/cfst"

# 专用 curl
#
# 使用 MIPSel MUSL 版本 curl 8.15.0
# 不使用 EdgeOS 系统自带 curl
CURL_BIN="$BASE_DIR/bin/curl"

# 测速结果
RESULT_FILE="$BASE_DIR/result.csv"

# 日志目录
LOG_DIR="$BASE_DIR/logs"

# 锁目录
LOCK_DIR="/tmp/cfst_ddns.lock"


# 创建日志目录
mkdir -p "$LOG_DIR"

# 当天日志
LOG_FILE="$LOG_DIR/cfst_ddns_$(date '+%F').log"


# ==================== 日志函数 ====================

log() {
    echo "[$(date '+%F %T')] [PID:$$] [$1] $2" | tee -a "$LOG_FILE"
}


# ==================== 清理旧日志 ====================

clean_logs() {
    find "$LOG_DIR" \
        -type f \
        -name "cfst_ddns_*.log" \
        -mtime +7 \
        -exec rm -f {} \; 2>/dev/null || true
}


# ==================== 检查运行环境 ====================

check_dependencies() {

    # 检查 CFST

    if [[ ! -x "$CFST_BIN" ]]; then

        log ERROR "CFST 不存在或没有执行权限: $CFST_BIN"

        return 1

    fi


    # 检查专用 curl

    if [[ ! -x "$CURL_BIN" ]]; then

        log ERROR "专用 curl 不存在或没有执行权限: $CURL_BIN"

        return 1

    fi


    # 检查 jq

    if ! command -v jq >/dev/null 2>&1; then

        log ERROR "jq 未安装或无法执行"

        return 1

    fi


    log INFO "CFST : $CFST_BIN"

    log INFO "curl : $CURL_BIN"

    log INFO "jq   : $(command -v jq)"


    # 检查专用 curl 是否能够正常启动

    if ! "$CURL_BIN" --version >/dev/null 2>&1; then

        log ERROR "专用 curl 无法正常启动: $CURL_BIN"

        return 1

    fi


    # 输出 curl 版本

    CURL_VERSION=$("$CURL_BIN" --version | head -1)

    log INFO "curl 版本: $CURL_VERSION"


    return 0

}


# ==================== 进程锁 ====================
#
# 不依赖 flock
# 使用 mkdir 原子创建目录实现互斥锁
#
# 如果已有任务运行，则退出
# ====================

lock() {

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then

        log WARN "已有任务正在运行，本次退出"

        exit 0

    fi

    echo "$$" > "$LOCK_DIR/pid"

    log INFO "进程锁获取成功"

}


# ==================== 释放锁 ====================

unlock() {

    if [[ -d "$LOCK_DIR" ]]; then

        rm -rf "$LOCK_DIR"

    fi

}


# ==================== 退出自动释放锁 ====================

trap unlock EXIT


# ==================== 超时看门狗 ====================
#
# 不依赖 timeout 命令
# 超过 MAX_RUNTIME 秒后终止主进程
# ====================

WATCHDOG_PID=""


start_watchdog() {

    (

        sleep "$MAX_RUNTIME"

        log ERROR "任务运行超过 ${MAX_RUNTIME} 秒，强制退出"

        kill -TERM "$$" 2>/dev/null || true

        sleep 5

        kill -9 "$$" 2>/dev/null || true

    ) &

    WATCHDOG_PID=$!

}


stop_watchdog() {

    if [[ -n "$WATCHDOG_PID" ]]; then

        kill "$WATCHDOG_PID" 2>/dev/null || true

        wait "$WATCHDOG_PID" 2>/dev/null || true

        WATCHDOG_PID=""

        log INFO "看门狗已停止并清理完成"

    fi

}


# ==================== CFST 测速函数 ====================

speed_test() {

    # 默认测速参数

    local n=50

    local t=4

    local dn=10

    local dt=10

    local tp=443

    local tl=200

    local tll=20

    local tlr=0

    local sl=0.01

    local p=10


    # 获取当前小时
    HOUR=$(date +%H | sed 's/^0//')


    # 晚高峰：19:00 - 23:00
    if (( HOUR >= 19 && HOUR <= 23 )); then

        t=8

        dt=15

        tl=220

        tlr=0.2

    fi


    log INFO "开始 CFST 测速"

    log INFO "参数: n=$n t=$t dn=$dn dt=$dt tl=$tl tlr=$tlr sl=$sl"


    # 检查 CFST 文件

    if [[ ! -x "$CFST_BIN" ]]; then

        log ERROR "CFST 不存在或没有执行权限: $CFST_BIN"

        return 1

    fi


    # 清理旧结果

    rm -f "$RESULT_FILE"


    cd "$BASE_DIR"


    # 构建 CFST 命令

    CMD=(

        "$CFST_BIN"

        -n "$n"

        -t "$t"

        -dn "$dn"

        -dt "$dt"

        -tp "$tp"

        -url "$CUSTOM_SPEED_URL"

        -tl "$tl"

        -tll "$tll"

        -tlr "$tlr"

        -sl "$sl"

        -p "$p"

        -o "$RESULT_FILE"

    )


    log INFO "执行 CFST 命令"

    printf '%q ' "${CMD[@]}" >> "$LOG_FILE"

    echo >> "$LOG_FILE"


    # 记录开始时间

    START=$(date +%s)


    # 直接执行 CFST
    #
    # 注意：
    # 这里不使用 timeout 命令
    # 由上面的 watchdog 负责最大运行时间保护

    if ! "${CMD[@]}"; then

        log ERROR "CFST 测速失败"

        return 1

    fi


    END=$(date +%s)


    log INFO "CFST 测速完成，耗时 $((END - START)) 秒"


    # 检查结果文件

    if [[ ! -s "$RESULT_FILE" ]]; then

        log ERROR "测速结果文件为空或不存在"

        return 1

    fi


    # 从 CSV 中提取速度最高的 IP
    #
    # CSV 格式通常为：
    #
    # IP,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区...
    #
    # 第 6 列为下载速度

    read IP SPEED_RAW <<< "$(
        awk -F',' '
            NR > 1 && $6 + 0 > max {
                max = $6
                ip = $1
            }
            END {
                print ip, max
            }
        ' "$RESULT_FILE"
    )"


    # 提取纯数字速度

    SPEED=$(echo "$SPEED_RAW" | grep -Eo '[0-9]+(\.[0-9]+)?' || true)


    if [[ -z "$IP" || -z "$SPEED" ]]; then

        log ERROR "无法解析有效的测速结果"

        return 1

    fi


    log INFO "最佳 IP : $IP"

    log INFO "下载速度: ${SPEED} MB/s"

}


# ==================== Cloudflare DNS 更新函数 ====================

update_dns() {

    if [[ -z "$IP" ]]; then

        log ERROR "IP 为空，无法更新 DNS"

        return 1

    fi


    log INFO "开始更新 DNS: $RECORD_NAME → $IP"


    # ==================== 查询 DNS 记录 ID ====================

    RES=$("$CURL_BIN" -s \
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


    # ==================== 更新 DNS ====================

    RES=$("$CURL_BIN" -s \
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
#
# Worker /api/upload 要求：
# POST Body 必须直接是 JSON 数组
#
# 不改变原有上传格式
# ====================

upload() {

    if [[ ! -f "$RESULT_FILE" ]]; then

        log ERROR "测速结果文件不存在，无法上传"

        return 1

    fi


    log INFO "开始生成上传数据"


    TIME=$(date "+%F %T")

    JSON=()


    # 读取 CSV
    # 跳过表头

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
                --arg ip "$ip" \
                --arg speed "$speed" \
                --arg latency "$latency" \
                --arg region "$region" \
                --arg time "$TIME" \
                --arg carrier "$CARRIER" \
                '{
                    ip: $ip,
                    speed: ($speed | tonumber?),
                    latency: $latency,
                    region: $region,
                    time: $time,
                    carrier: $carrier
                }')


            JSON+=("$ITEM")


        done


    } < "$RESULT_FILE"


    # 合并为 JSON 数组

    DATA=$(printf '%s\n' "${JSON[@]}" | jq -s '.')


    COUNT=$(echo "$DATA" | jq length)


    log INFO "准备上传节点数量: $COUNT"


    # ==================== 上传 ====================

    # 直接上传 JSON 数组
    # 不增加外层对象

    PAYLOAD="$DATA"


    log INFO "上传数据格式: JSON Array"


    RESPONSE=$("$CURL_BIN" -s \
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

    log INFO "运营商 : $CARRIER"

    log INFO "域名   : $RECORD_NAME"

    log INFO "========================================"


    # 获取进程锁

    lock


    # 检查运行环境

    if ! check_dependencies; then

        log ERROR "运行环境检查失败，任务退出"

        exit 1

    fi
	
	# 自动检测当前线路运营商
	detect_carrier

    # 启动超时保护
    start_watchdog


    # ==================== 1. CFST 测速 ====================

    if ! speed_test; then

        log ERROR "CFST 测速失败，无法继续执行"

        exit 1

    fi


    # ==================== 2. Cloudflare DNS 更新 ====================
    #
    # DNS 更新独立执行
    # 失败不影响后面的上传

    if update_dns; then

        log INFO "DNS 更新任务完成"

    else

        log WARN "DNS 更新任务失败，但不影响测速结果上传"

    fi


    # ==================== 3. 上传测速结果 ====================
    #
    # 上传任务独立于 DNS

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


# ==================== 执行 ====================

main
