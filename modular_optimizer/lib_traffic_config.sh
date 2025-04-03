#!/bin/bash
# lib_traffic_config.sh - Traffic Monitor Configuration and Management (v1.3)

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
# Assume TRAFFIC_CONFIG_FILE, TRAFFIC_CRON_FILE, LOG_FILE, SCRIPT_DIR, TRAFFIC_WRAPPER_SCRIPT, TRAFFIC_LOG_FILE are exported
# shellcheck source=./lib_utils.sh
source "$SCRIPT_DIR/lib_utils.sh" # For log, clear_cmd, validate_*, check_command, get_ssh_port

# --- Functions ---

# Load traffic monitor config, providing defaults
load_traffic_config() {
    log "加载流量监控配置: $TRAFFIC_CONFIG_FILE"
    # --- Defaults ---
    ENABLE_TRAFFIC_MONITOR="false"; TELEGRAM_BOT_TOKEN=""; CHAT_ID=""; ENABLE_LIMIT="false"; LIMIT_GB=200; ENABLE_RESET="true"; RESET_DAY=1; SSH_PORT=22; OVER_LIMIT_ACTION="limit_net"; TRAFFIC_CRON_FREQ="*/5";

    if [ -f "$TRAFFIC_CONFIG_FILE" ]; then
        source "$TRAFFIC_CONFIG_FILE" || log "警告: 加载流量监控配置 $TRAFFIC_CONFIG_FILE 时出错"
        log "已加载现有流量监控配置。"
        # Validate loaded values
        [[ "$ENABLE_TRAFFIC_MONITOR" != "true" ]] && ENABLE_TRAFFIC_MONITOR="false"
        [[ "$ENABLE_LIMIT" != "true" ]] && ENABLE_LIMIT="false"
        [[ "$ENABLE_RESET" != "true" ]] && ENABLE_RESET="false"
        # Extra check for SSH_PORT after sourcing
        if [[ -n "${SSH_PORT}" && ! "${SSH_PORT}" =~ ^[0-9]+$ ]]; then log "警告: 配置文件中 SSH_PORT ('${SSH_PORT}') 无效，将使用默认值 22。"; SSH_PORT=22; fi
        validate_numeric "${LIMIT_GB:-200}" "Limit GB" || LIMIT_GB=200; [[ "$LIMIT_GB" -lt 0 ]] && LIMIT_GB=0
        validate_numeric "${RESET_DAY:-1}" "Reset Day" || RESET_DAY=1; [[ "$RESET_DAY" -lt 1 || "$RESET_DAY" -gt 31 ]] && RESET_DAY=1
        validate_numeric "${SSH_PORT:-22}" "SSH Port" || SSH_PORT=22
        case "$OVER_LIMIT_ACTION" in limit_net|shutdown|notify_only) ;; *) OVER_LIMIT_ACTION="limit_net";; esac
        [[ -z "$TRAFFIC_LOG_FILE" ]] && TRAFFIC_LOG_FILE="/var/log/traffic_monitor.log" # Use fixed default log
        [[ ! "$TRAFFIC_CRON_FREQ" =~ ^(\*\/[0-9]+|[0-9\*\/\,-]+)$ ]] && TRAFFIC_CRON_FREQ="*/5"
    else
        log "未找到流量监控配置文件 $TRAFFIC_CONFIG_FILE, 将使用默认或提示输入。"
        SSH_PORT=$(get_ssh_port | tail -n 1) # Detect SSH port for default if file not found, ensure only port number
    fi
    # Export variables
    export ENABLE_TRAFFIC_MONITOR TELEGRAM_BOT_TOKEN CHAT_ID ENABLE_LIMIT LIMIT_GB ENABLE_RESET RESET_DAY SSH_PORT OVER_LIMIT_ACTION TRAFFIC_LOG_FILE TRAFFIC_CRON_FREQ
}

# Interactive configuration for traffic monitor
configure_traffic_monitor() {
    log "运行流量监控配置向导"
    log "检查流量监控依赖..."
    if ! command -v vnstat >/dev/null 2>&1; then
        log "未找到 vnstat，正在安装..."
        apt-get update && apt-get install -y vnstat || { log "错误: 安装 vnstat 失败"; echo -e "\033[31m错误: 无法安装 vnstat，请手动安装后重试。\033[0m"; return 1; }
        systemctl enable vnstat || log "警告: 无法启用 vnstat 服务"
        systemctl start vnstat || log "警告: 无法启动 vnstat 服务"
        log "vnstat 已安装并启动"
    fi
    if ! command -v bc >/dev/null 2>&1; then
        log "未找到 bc，正在安装..."
        apt-get install -y bc || { log "错误: 安装 bc 失败"; echo -e "\033[31m错误: 无法安装 bc，请手动安装后重试。\033[0m"; return 1; }
        log "bc 已安装"
    fi
    if ! command -v curl >/dev/null 2>&1; then
        log "未找到 curl，正在安装..."
        apt-get install -y curl || { log "错误: 安装 curl 失败"; echo -e "\033[31m错误: 无法安装 curl，请手动安装后重试。\033[0m"; return 1; }
        log "curl 已安装"
    fi
    echo -e "\n\033[36m--- 流量监控配置向导 ---\033[0m"
    load_traffic_config # Load current or default values

    local confirm_enable input_token input_chatid confirm_limit input_limit_gb input_reset_day action_choice input_log_path detected_ssh_port confirm_reset

    read -p "是否启用流量监控? (y/N) [当前: $ENABLE_TRAFFIC_MONITOR]: " confirm_enable; ENABLE_TRAFFIC_MONITOR=$([[ "$confirm_enable" == "y" || "$confirm_enable" == "Y" ]] && echo "true" || echo "false")
    read -p "输入 Telegram Bot Token [当前: ${TELEGRAM_BOT_TOKEN:--空-}]: " input_token; TELEGRAM_BOT_TOKEN=${input_token:-$TELEGRAM_BOT_TOKEN}
    read -p "输入 Telegram Chat ID [当前: ${CHAT_ID:--空-}]: " input_chatid; CHAT_ID=${input_chatid:-$CHAT_ID}
    read -p "是否启用流量限制? (y/N) [当前: $ENABLE_LIMIT]: " confirm_limit; ENABLE_LIMIT=$([[ "$confirm_limit" == "y" || "$confirm_limit" == "Y" ]] && echo "true" || echo "false")
    if [[ "$ENABLE_LIMIT" == "true" ]]; then read -p "输入月度流量限制 (GB) [当前: $LIMIT_GB]: " input_limit_gb; input_limit_gb=${input_limit_gb:-$LIMIT_GB}; if validate_numeric "$input_limit_gb" "流量限制"; then LIMIT_GB=$input_limit_gb; else echo "输入无效，保留当前值 $LIMIT_GB"; fi; else LIMIT_GB=0; fi
    read -p "是否每月重置流量统计? (y/N) [当前: $ENABLE_RESET]: " confirm_reset; ENABLE_RESET=$([[ "$confirm_reset" == "y" || "$confirm_reset" == "Y" ]] && echo "true" || echo "false")
    if [[ "$ENABLE_RESET" == "true" ]]; then read -p "输入每月重置日期 (1-31) [当前: $RESET_DAY]: " input_reset_day; input_reset_day=${input_reset_day:-$RESET_DAY}; if validate_numeric "$input_reset_day" "重置日期" && [ "$input_reset_day" -ge 1 ] && [ "$input_reset_day" -le 31 ]; then RESET_DAY=$input_reset_day; else echo "输入无效，保留当前值 $RESET_DAY"; fi; fi

    detected_ssh_port=$(get_ssh_port | tail -n 1) # 只取端口号，忽略日志
    echo "自动检测到的 SSH 端口: $detected_ssh_port (用于流量超限时放行)"
    SSH_PORT="$detected_ssh_port"
    echo "流量超限时操作选项 [当前: $OVER_LIMIT_ACTION]:"
    echo "  1) limit_net  : 限制网络 (仅SSH)"
    echo "  2) shutdown   : 关机"
    echo "  3) notify_only: 仅通知"
    read -p "请选择超限操作 (1/2/3) [回车保留当前]: " action_choice
    case "$action_choice" in
        1) OVER_LIMIT_ACTION="limit_net";;
        2) OVER_LIMIT_ACTION="shutdown";;
        3) OVER_LIMIT_ACTION="notify_only";;
        "") ;;
        *) echo "无效选择，保留当前: $OVER_LIMIT_ACTION";;
    esac

    # Log path - use fixed default, no need to prompt
    TRAFFIC_LOG_FILE="/var/log/traffic_monitor.log"
    echo "使用的流量监控日志路径 (固定): $TRAFFIC_LOG_FILE"
    if ! mkdir -p "$(dirname "$TRAFFIC_LOG_FILE")"; then log "错误: 无法创建日志目录 $(dirname "$TRAFFIC_LOG_FILE")"; echo "错误: 无法创建日志目录"; return 1; fi
    if ! touch "$TRAFFIC_LOG_FILE"; then log "错误: 无法写入日志文件 $TRAFFIC_LOG_FILE"; echo "错误: 无法写入日志文件"; return 1; fi
    chmod 644 "$TRAFFIC_LOG_FILE" 2>/dev/null || log "警告: 无法设置流量日志权限"

    log "保存流量监控配置到 $TRAFFIC_CONFIG_FILE"
    cat > "$TRAFFIC_CONFIG_FILE" <<EOF
# Traffic Monitor Configuration File
# Generated: $(date)
ENABLE_TRAFFIC_MONITOR="$ENABLE_TRAFFIC_MONITOR"
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
CHAT_ID="$CHAT_ID"
ENABLE_LIMIT="$ENABLE_LIMIT"
LIMIT_GB="$LIMIT_GB"
ENABLE_RESET="$ENABLE_RESET"
RESET_DAY="$RESET_DAY"
SSH_PORT="$SSH_PORT"
OVER_LIMIT_ACTION="$OVER_LIMIT_ACTION"
TRAFFIC_LOG_FILE="$TRAFFIC_LOG_FILE"
TRAFFIC_CRON_FREQ="${TRAFFIC_CRON_FREQ:-*/5}"
EOF
    if [ $? -eq 0 ]; then
        chmod 600 "$TRAFFIC_CONFIG_FILE" || log "警告: 设置 $TRAFFIC_CONFIG_FILE 权限失败"
        echo -e "\033[32m✔ 流量监控配置已保存。\033[0m"
        log "流量监控配置保存成功"
    else
        log "错误: 写入 $TRAFFIC_CONFIG_FILE 失败"
        echo -e "\033[31m✗ 写入流量监控配置文件失败！\033[0m"
        return 1
    fi
    return 0
}

# Manage Cron job for integrated traffic monitor
manage_traffic_cron() {
    log "运行内置流量监控 Cron 管理"
    load_traffic_config # Load config

    if [[ "$ENABLE_TRAFFIC_MONITOR" != "true" ]]; then
        log "流量监控未启用，移除 Cron 任务"
        if [ -f "$TRAFFIC_CRON_FILE" ]; then rm -f "$TRAFFIC_CRON_FILE" && log "已移除 $TRAFFIC_CRON_FILE" || log "错误: 移除 $TRAFFIC_CRON_FILE 失败"; fi
        echo -e "\033[33m流量监控当前已禁用。\033[0m 可在配置菜单中启用。"
        return 0
    fi

    echo -e "\n\033[36m--- 内置流量监控计划任务管理 ---\033[0m"
    echo "监控日志文件: $TRAFFIC_LOG_FILE"

    # Check dependencies needed by the internal logic
    check_command "vnstat" || return 1
    check_command "bc" || return 1
    check_command "curl" || return 1
    if [[ "$OVER_LIMIT_ACTION" == "limit_net" ]]; then check_command "iptables" || return 1; fi
    if [[ "$OVER_LIMIT_ACTION" == "shutdown" ]]; then check_command "shutdown" || return 1; fi

    # Check if wrapper script exists (should be generated by install_script)
    if [ ! -x "$TRAFFIC_WRAPPER_SCRIPT" ]; then
        log "错误: 流量监控包装脚本 $TRAFFIC_WRAPPER_SCRIPT 未找到或不可执行"
        echo -e "\033[31m错误: 流量监控执行脚本 $TRAFFIC_WRAPPER_SCRIPT 未找到!\033[0m"
        echo "请尝试重新运行主菜单选项 1 (安装/更新脚本) 来生成它。"
        return 1
    fi

    echo -n "当前计划任务状态: "; if [ -f "$TRAFFIC_CRON_FILE" ]; then echo "已设置 ($(grep . "$TRAFFIC_CRON_FILE" | awk '{print $1}' || echo "$TRAFFIC_CRON_FREQ") * * * *)"; else echo "未设置。"; fi

    read -p "输入 Cron 执行频率 (例如 '*/5' 表示每5分钟) [默认: $TRAFFIC_CRON_FREQ]: " input_freq; TRAFFIC_CRON_FREQ=${input_freq:-$TRAFFIC_CRON_FREQ}
    if [[ ! "$TRAFFIC_CRON_FREQ" =~ ^(\*\/[0-9]+|[0-9\*\/\,-]+)$ ]]; then echo "频率格式无效，使用默认 '*/5'"; TRAFFIC_CRON_FREQ="*/5"; fi

    # Update config file with new frequency
    if [ -f "$TRAFFIC_CONFIG_FILE" ]; then grep -q "^TRAFFIC_CRON_FREQ=" "$TRAFFIC_CONFIG_FILE" && sed -i "s|^TRAFFIC_CRON_FREQ=.*|TRAFFIC_CRON_FREQ=\"$TRAFFIC_CRON_FREQ\"|" "$TRAFFIC_CONFIG_FILE" || echo "TRAFFIC_CRON_FREQ=\"$TRAFFIC_CRON_FREQ\"" >> "$TRAFFIC_CONFIG_FILE"; fi

    # Ensure log file is writable
    if ! touch "$TRAFFIC_LOG_FILE"; then log "错误: 无法写入日志文件 $TRAFFIC_LOG_FILE"; echo "错误: 无法写入日志文件"; return 1; fi
    chmod 644 "$TRAFFIC_LOG_FILE" 2>/dev/null || log "警告: 无法设置流量日志权限"

    # Cron command now runs the wrapper script
    local cron_command; cron_command=$(printf "%s * * * * root /bin/bash %q >> %q 2>&1" "$TRAFFIC_CRON_FREQ" "$TRAFFIC_WRAPPER_SCRIPT" "$TRAFFIC_LOG_FILE")

    echo "$cron_command" > "$TRAFFIC_CRON_FILE"
    if [ $? -eq 0 ]; then chmod 644 "$TRAFFIC_CRON_FILE" || log "警告: 设置 $TRAFFIC_CRON_FILE 权限失败"; log "流量监控 Cron 设置/更新: $TRAFFIC_CRON_FILE"; echo -e "\033[32m✔ 流量监控计划任务已设置为 '$TRAFFIC_CRON_FREQ * * * *'。\033[0m";
    else log "错误: 写入 $TRAFFIC_CRON_FILE 失败"; echo -e "\033[31m✗ 写入流量监控 Cron 文件失败！\033[0m"; return 1; fi
    echo "提示：系统通常会自动加载 /etc/cron.d/ 下的任务。"
    return 0
}

# --- Core Traffic Monitoring Logic (Adapted from user script) ---
run_traffic_monitor_check() {
    # This function now contains the logic previously in the external script
    log "--- [内置] 流量监控检查开始 ---"
    load_traffic_config # Load settings from /etc/traffic_monitor.conf

    if [[ "$ENABLE_TRAFFIC_MONITOR" != "true" ]]; then
        log "流量监控已禁用 (配置)"
        log "--- [内置] 流量监控检查结束 (已禁用) ---"
        return 0
    fi

    # Check dependencies again (important if run directly/from cron)
    check_command "vnstat" || return 1
    check_command "bc" || return 1
    check_command "curl" || return 1 # For Telegram
    if [[ "$OVER_LIMIT_ACTION" == "limit_net" ]]; then check_command "iptables" || return 1; fi
    if [[ "$OVER_LIMIT_ACTION" == "shutdown" ]]; then check_command "shutdown" || return 1; fi

    local INTERFACE LIMIT_MIB THRESHOLD_1_MIB THRESHOLD_2_MIB THRESHOLD_3_MIB CURRENT_DAY LAST_DAY_OF_MONTH IS_RESET_DAY DATA CURRENT_MONTH TRAFFIC_RX_MIB TRAFFIC_TX_MIB TRAFFIC_TO_CHECK_MIB TRAFFIC_TO_CHECK_GB usage_percent message flag_file

    # --- Flag file paths (use /var/run or /tmp) ---
    local FLAG_DIR="/var/run/traffic_monitor"
    mkdir -p "$FLAG_DIR" || { log "错误: 无法创建标志目录 $FLAG_DIR"; return 1; }
    local DAILY_REPORT_SENT_FLAG="$FLAG_DIR/daily_report_sent"
    local THRESHOLD_1_FLAG="$FLAG_DIR/vnstat_threshold_1"
    local THRESHOLD_2_FLAG="$FLAG_DIR/vnstat_threshold_2"
    local THRESHOLD_3_FLAG="$FLAG_DIR/vnstat_threshold_3"
    local VNSTAT_RESET_FLAG="$FLAG_DIR/vnstat_reset"

    # --- Get Interface ---
    INTERFACE=$(ip route get 8.8.8.8 | awk -- '{print $5; exit}')
    if [ -z "$INTERFACE" ]; then
        log "错误: 无法检测到默认网络接口。"
        send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$(date '+%Y-%m-%d %H:%M:%S') 流量监控错误：无法检测到网络接口。"
        return 1
    fi
    log "监控网络接口: $INTERFACE"

    # --- Initialize vnstat for interface if necessary ---
    if ! vnstat -i "$INTERFACE" > /dev/null 2>&1; then
        log "接口 $INTERFACE 未被 vnstat 监控，尝试添加..."
        if vnstat --add -i "$INTERFACE"; then
            log "接口 $INTERFACE 已添加到 vnstat 数据库。"
        else
            log "错误: 无法将接口 $INTERFACE 添加到 vnstat 数据库。"
            send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$(date '+%Y-%m-%d %H:%M:%S') 流量监控错误：无法添加接口 $INTERFACE 到 vnstat。"
            return 1
        fi
    fi

    # --- Calculate Limits (only if limit is enabled) ---
    if [[ "$ENABLE_LIMIT" == "true" && "$LIMIT_GB" -gt 0 ]]; then
        LIMIT_MIB=$(echo "$LIMIT_GB * 1024" | bc)
        log "流量限制: $LIMIT_GB GB ($LIMIT_MIB MiB)"
        # Thresholds are optional, default to 0 if not set or invalid
        validate_numeric "${THRESHOLD_1:-80}" "阈值1" || THRESHOLD_1=80; [[ "$THRESHOLD_1" -lt 0 || "$THRESHOLD_1" -gt 100 ]] && THRESHOLD_1=0
        validate_numeric "${THRESHOLD_2:-90}" "阈值2" || THRESHOLD_2=90; [[ "$THRESHOLD_2" -lt 0 || "$THRESHOLD_2" -gt 100 ]] && THRESHOLD_2=0
        validate_numeric "${THRESHOLD_3:-0}" "阈值3" || THRESHOLD_3=0; [[ "$THRESHOLD_3" -lt 0 || "$THRESHOLD_3" -gt 100 ]] && THRESHOLD_3=0
        THRESHOLD_1_MIB=$(echo "$LIMIT_MIB * $THRESHOLD_1 / 100" | bc); log "阈值 1: $THRESHOLD_1% ($THRESHOLD_1_MIB MiB)"
        if [ "$THRESHOLD_2" -ne 0 ]; then THRESHOLD_2_MIB=$(echo "$LIMIT_MIB * $THRESHOLD_2 / 100" | bc); log "阈值 2: $THRESHOLD_2% ($THRESHOLD_2_MIB MiB)"; fi
        if [ "$THRESHOLD_3" -ne 0 ]; then THRESHOLD_3_MIB=$(echo "$LIMIT_MIB * $THRESHOLD_3 / 100" | bc); log "阈值 3: $THRESHOLD_3% ($THRESHOLD_3_MIB MiB)"; fi
    else
        log "流量限制未启用或限制值为0。"
        LIMIT_GB=0 # Ensure it's 0 if disabled
        LIMIT_MIB=0
        THRESHOLD_1=0; THRESHOLD_2=0; THRESHOLD_3=0; # Disable thresholds too
    fi

    # --- Reset Logic ---
    if [[ "$ENABLE_RESET" == "true" ]]; then
        CURRENT_DAY=$(date +'%-d')
        LAST_DAY_OF_MONTH=$(date -d "$(date +'%Y-%m-01') +1 month -1 day" +%d)
        IS_RESET_DAY=false
        if [ "$CURRENT_DAY" -eq "$RESET_DAY" ]; then IS_RESET_DAY=true;
        elif [ "$RESET_DAY" -gt "$LAST_DAY_OF_MONTH" ] && [ "$CURRENT_DAY" -eq "$LAST_DAY_OF_MONTH" ]; then IS_RESET_DAY=true; fi

        if $IS_RESET_DAY; then
            if [ ! -f "$VNSTAT_RESET_FLAG" ]; then
                log "重置日，尝试重置接口 $INTERFACE 流量..."
                # Try removing and re-adding interface first
                if vnstat --remove -i "$INTERFACE" --force; then
                     log "vnstat 接口 $INTERFACE 已移除"
                     sleep 1 # Give vnstat time
                     if vnstat --add -i "$INTERFACE"; then
                         log "vnstat 接口 $INTERFACE 已重新添加"
                         sleep 1
                         if systemctl restart vnstat; then
                              log "vnstat 服务重启成功，流量已重置。"
                              rm -f "$THRESHOLD_1_FLAG" "$THRESHOLD_2_FLAG" "$THRESHOLD_3_FLAG" "$DAILY_REPORT_SENT_FLAG" # Clear all flags
                              touch "$VNSTAT_RESET_FLAG"
                              send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$(date '+%Y-%m-%d %H:%M:%S') 服务器 [$HOSTNAME] 流量已于重置日 ($CURRENT_DAY) 重置。"
                         else
                              log "错误: 重启 vnstat 服务失败"
                              send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$(date '+%Y-%m-%d %H:%M:%S') 流量监控错误：重置流量后重启 vnstat 服务失败。"
                              touch "$VNSTAT_RESET_FLAG" # Still set flag to prevent retries today
                         fi
                     else
                         log "错误: 重新添加接口 $INTERFACE 失败"
                         send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$(date '+%Y-%m-%d %H:%M:%S') 流量监控错误：重置流量时重新添加接口 $INTERFACE 失败。"
                         touch "$VNSTAT_RESET_FLAG"
                     fi
                else
                    log "错误: 移除接口 $INTERFACE 失败，尝试清空数据库..."
                    # Fallback: try clearing database (less reliable)
                    local vnstat_db_path="/var/lib/vnstat/$INTERFACE"
                    if [ -f "$vnstat_db_path" ]; then
                         cp "$vnstat_db_path" "${vnstat_db_path}.bak.$(date +%s)" && log "已备份 vnstat 数据库"
                         if echo "" > "$vnstat_db_path"; then
                              log "vnstat 数据库已清空"
                              if systemctl restart vnstat; then
                                   log "vnstat 服务重启成功，流量已重置 (数据库方式)。"
                                   rm -f "$THRESHOLD_1_FLAG" "$THRESHOLD_2_FLAG" "$THRESHOLD_3_FLAG" "$DAILY_REPORT_SENT_FLAG"
                                   touch "$VNSTAT_RESET_FLAG"
                                   send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$(date '+%Y-%m-%d %H:%M:%S') 服务器 [$HOSTNAME] 流量已于重置日 ($CURRENT_DAY) 重置 (数据库方式)。"
                              else
                                   log "错误: 清空数据库后重启 vnstat 服务失败"
                                   send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$(date '+%Y-%m-%d %H:%M:%S') 流量监控错误：清空数据库后重启 vnstat 服务失败。"
                                   touch "$VNSTAT_RESET_FLAG"
                              fi
                         else
                              log "错误: 清空 vnstat 数据库 $vnstat_db_path 失败"
                              send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$(date '+%Y-%m-%d %H:%M:%S') 流量监控错误：重置流量失败（清空数据库失败）。"
                              touch "$VNSTAT_RESET_FLAG"
                         fi
                    else
                         log "错误: 找不到 vnstat 数据库文件 $vnstat_db_path"
                         send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$(date '+%Y-%m-%d %H:%M:%S') 流量监控错误：重置流量失败（找不到数据库文件）。"
                         touch "$VNSTAT_RESET_FLAG"
                    fi
                fi
            else
                log "流量今日已重置过。"
            fi
        else # Not reset day
            if [ -f "$VNSTAT_RESET_FLAG" ]; then rm -f "$VNSTAT_RESET_FLAG"; log "移除每日重置标志"; fi
        fi
    else
        log "流量重置已禁用 (配置)"
    fi

    # --- Get Current Traffic ---
    # Wait a bit after potential restart
    if $IS_RESET_DAY; then sleep 5; fi

    DATA=$(vnstat -i "$INTERFACE" --oneline 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$DATA" ]; then log "错误: vnstat 命令获取 $INTERFACE 数据失败。"; send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$(date '+%Y-%m-%d %H:%M:%S') 流量监控错误：vnstat 命令获取 $INTERFACE 数据失败。"; return 1; fi

    CURRENT_MONTH=$(echo "$DATA" | cut -d ';' -f 8); TRAFFIC_RX_RAW=$(echo "$DATA" | cut -d ';' -f 9); TRAFFIC_TX_RAW=$(echo "$DATA" | cut -d ';' -f 10)
    TRAFFIC_RX_MIB=$(echo "$TRAFFIC_RX_RAW" | tr -d ' ' | sed 's/GiB/*1024/;s/TiB/*1024*1024/;s/MiB//;s/KiB/\/1024/' | bc -l 2>/dev/null || echo 0)
    TRAFFIC_TX_MIB=$(echo "$TRAFFIC_TX_RAW" | tr -d ' ' | sed 's/GiB/*1024/;s/TiB/*1024*1024/;s/MiB//;s/KiB/\/1024/' | bc -l 2>/dev/null || echo 0)
    TRAFFIC_RX_MIB=${TRAFFIC_RX_MIB:-0}; TRAFFIC_TX_MIB=${TRAFFIC_TX_MIB:-0}
    log "本月 ($CURRENT_MONTH) 用量: RX = $TRAFFIC_RX_RAW ($TRAFFIC_RX_MIB MiB), TX = $TRAFFIC_TX_RAW ($TRAFFIC_TX_MIB MiB)"

    # Use max of RX/TX for checking limit
    TRAFFIC_TO_CHECK_MIB=$(echo "$TRAFFIC_TX_MIB $TRAFFIC_RX_MIB" | awk '{if ($1+0 > $2+0) print $1; else print $2}')
    log "用于检查限制的流量 (Max(RX, TX)): $TRAFFIC_TO_CHECK_MIB MiB"

    # --- Threshold Checks and Notifications (Only if limit enabled) ---
    if [[ "$ENABLE_LIMIT" == "true" && "$LIMIT_MIB" -gt 0 ]]; then
        usage_percent=$(echo "scale=2; ($TRAFFIC_TO_CHECK_MIB / $LIMIT_MIB) * 100" | bc)
        log "当前使用百分比: $usage_percent%"

        # Function to check and notify threshold
        check_threshold() {
            local threshold_num=$1 threshold_mib=$2 threshold_flag=$3
            if [[ "$threshold_num" -gt 0 && "$threshold_num" -le 100 ]]; then
                if (( $(echo "$TRAFFIC_TO_CHECK_MIB > $threshold_mib" | bc -l) )); then
                    if [ ! -f "$threshold_flag" ]; then
                        message="警告: 服务器 [$HOSTNAME] 月度流量已使用 ${TRAFFIC_TO_CHECK_MIB} MiB (${usage_percent}%), 超过 ${threshold_num}% 阈值 (${threshold_mib} MiB)。"
                        log "$message"; send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$(date '+%Y-%m-%d %H:%M:%S') $message"; touch "$threshold_flag";
                    fi
                fi
            fi
        }

        check_threshold "$THRESHOLD_1" "$THRESHOLD_1_MIB" "$THRESHOLD_1_FLAG"
        check_threshold "$THRESHOLD_2" "$THRESHOLD_2_MIB" "$THRESHOLD_2_FLAG"
        check_threshold "$THRESHOLD_3" "$THRESHOLD_3_MIB" "$THRESHOLD_3_FLAG"

        # --- Over Limit Action ---
        if (( $(echo "$TRAFFIC_TO_CHECK_MIB > $LIMIT_MIB" | bc -l) )); then
            log "警告: 流量超限! 用量: $TRAFFIC_TO_CHECK_MIB MiB, 限制: $LIMIT_MIB MiB. 执行操作: $OVER_LIMIT_ACTION"
            case "$OVER_LIMIT_ACTION" in
                "limit_net")
                    send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$(date '+%Y-%m-%d %H:%M:%S') 警告：服务器 [$HOSTNAME] 流量已超限 (${TRAFFIC_TO_CHECK_MIB} MiB / ${LIMIT_MIB} MiB)！限制网络，仅保留 SSH (端口 $SSH_PORT)。"
                    log "应用防火墙规则 (仅允许 SSH $SSH_PORT 和回环)"
                    iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT; iptables -F INPUT; iptables -F FORWARD; iptables -A INPUT -i lo -j ACCEPT; iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT;
                    if command -v ip6tables >/dev/null; then ip6tables -P INPUT DROP; ip6tables -P FORWARD DROP; ip6tables -P OUTPUT ACCEPT; ip6tables -F INPUT; ip6tables -F FORWARD; ip6tables -A INPUT -i lo -j ACCEPT; ip6tables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT; ip6tables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT; fi
                    log "防火墙规则已应用"
                    ;;
                "shutdown")
                    log "流量超限，执行关机！"
                    send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$(date '+%Y-%m-%d %H:%M:%S') 严重警告：服务器 [$HOSTNAME] 流量已超限！将立即关机！"
                    sleep 5 # Give Telegram message time to send
                    shutdown -h now
                    ;;
                "notify_only")
                    log "流量超限，仅通知。"
                    send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$(date '+%Y-%m-%d %H:%M:%S') 警告：服务器 [$HOSTNAME] 流量已超限 (${TRAFFIC_TO_CHECK_MIB} MiB / ${LIMIT_MIB} MiB)！未执行操作。"
                    ;;
            esac
        fi # End over limit check
    fi # End limit enabled check

    # --- Daily Report ---
    local current_hour=$(date +%H)
    # Report around 10:00 AM
    if [[ "$current_hour" -eq 10 ]]; then
        if [ ! -f "$DAILY_REPORT_SENT_FLAG" ]; then
            log "生成每日流量报告..."
            local SCALE=1 REPORT_RX_GB REPORT_TX_GB REPORT_MAX_GB REMAINING_LIMIT_MIB REMAINING_LIMIT_GB REMAINING_LIMIT_PERCENT report_message
            REPORT_RX_GB=$(echo "scale=$SCALE; $TRAFFIC_RX_MIB / 1024" | bc)
            REPORT_TX_GB=$(echo "scale=$SCALE; $TRAFFIC_TX_MIB / 1024" | bc)
            REPORT_MAX_GB=$(echo "scale=$SCALE; $TRAFFIC_TO_CHECK_MIB / 1024" | bc)
            if [[ "$ENABLE_LIMIT" == "true" && "$LIMIT_GB" -gt 0 ]]; then
                REMAINING_LIMIT_MIB=$(echo "$LIMIT_MIB - $TRAFFIC_TO_CHECK_MIB" | bc)
                if (( $(echo "$REMAINING_LIMIT_MIB < 0" | bc -l) )); then REMAINING_LIMIT_MIB=0; fi
                REMAINING_LIMIT_GB=$(echo "scale=$SCALE; $REMAINING_LIMIT_MIB / 1024" | bc)
                REMAINING_LIMIT_PERCENT=$(echo "scale=2; ($REMAINING_LIMIT_MIB * 100) / $LIMIT_MIB" | bc)
                if (( $(echo "$REMAINING_LIMIT_PERCENT < 0" | bc -l) )); then REMAINING_LIMIT_PERCENT=0.00; fi
                report_message="$(date '+%Y-%m-%d %H:%M:%S') 服务器 [$HOSTNAME] 流量报告\n接口: $INTERFACE | 月份: $CURRENT_MONTH\n⬆️ TX: $REPORT_TX_GB GB\n⬇️ RX: $REPORT_RX_GB GB\n使用 (Max): $REPORT_MAX_GB GB / ${LIMIT_GB} GB\n剩余 (估): $REMAINING_LIMIT_GB GB ($REMAINING_LIMIT_PERCENT%)"
            else
                report_message="$(date '+%Y-%m-%d %H:%M:%S') 服务器 [$HOSTNAME] 流量报告\n接口: $INTERFACE | 月份: $CURRENT_MONTH\n⬆️ TX: $REPORT_TX_GB GB\n⬇️ RX: $REPORT_RX_GB GB\n使用 (Max): $REPORT_MAX_GB GB (未设置限制)"
            fi
            send_to_telegram "$TELEGRAM_BOT_TOKEN" "$CHAT_ID" "$report_message" && touch "$DAILY_REPORT_SENT_FLAG"
        fi
    else # Not report time, remove flag
        if [ -f "$DAILY_REPORT_SENT_FLAG" ]; then rm -f "$DAILY_REPORT_SENT_FLAG"; log "移除每日报告标志"; fi
    fi

    log "--- [内置] 流量监控检查结束 ---"
    return $exit_code
}

# Traffic monitor config sub-menu
traffic_monitor_config_menu() {
    while true; do
        clear_cmd; echo -e "\033[34m🚦 流量监控管理 ▍\033[0m";
        load_traffic_config > /dev/null 2>&1
        local monitor_status limit_status reset_status action_desc cron_status
        monitor_status=$([[ "$ENABLE_TRAFFIC_MONITOR" == "true" ]] && echo -e "\033[32m已启用\033[0m" || echo -e "\033[31m已禁用\033[0m")
        limit_status=$([[ "$ENABLE_LIMIT" == "true" ]] && echo -e "${LIMIT_GB:-?} GB" || echo -e "未启用")
        reset_status=$([[ "$ENABLE_RESET" == "true" ]] && echo -e "每月 ${RESET_DAY:-?} 日" || echo -e "未启用")
        case "$OVER_LIMIT_ACTION" in limit_net) action_desc="限制网络(SSH)";; shutdown) action_desc="关机";; notify_only) action_desc="仅通知";; *) action_desc="未知";; esac
        cron_status=$([ -f "$TRAFFIC_CRON_FILE" ] && echo -e "\033[32m已设置 ($(grep . "$TRAFFIC_CRON_FILE" | awk '{print $1}' || echo "$TRAFFIC_CRON_FREQ") * * * *)\033[0m" || echo -e "\033[31m未设置\033[0m")

        echo -e "\n  \033[1m当前配置 ($TRAFFIC_CONFIG_FILE):\033[0m"
        printf "    %-20s: %s\n" "监控总开关" "$monitor_status"; printf "    %-20s: %s\n" "Telegram Token" "${TELEGRAM_BOT_TOKEN:-(未设置)-}"; printf "    %-20s: %s\n" "Telegram Chat ID" "${CHAT_ID:-(未设置)-}"; printf "    %-20s: %s\n" "流量限制" "$limit_status"; printf "    %-20s: %s\n" "月度重置" "$reset_status"; printf "    %-20s: %s\n" "SSH 端口 (超限放行)" "$SSH_PORT"; printf "    %-20s: %s\n" "超限操作" "$action_desc"; printf "    %-20s: %s\n" "监控日志路径" "$TRAFFIC_LOG_FILE"; printf "    %-20s: %s\n" "计划任务状态" "$cron_status";

        echo -e "\n  \033[1m操作选项:\033[0m"; echo "    1) ⚙️  修改监控配置参数"; echo "    2) ⏰ 设置/移除 Cron 任务"; echo "    3) 📄 查看监控日志"; echo "    4) ❓ 查看帮助/说明"; echo "    5) ↩️ 返回工具箱"; echo -e "\033[0m"; local choice; read -p "请输入选项 (1-5): " choice
        case $choice in
            1) configure_traffic_monitor ;;
            2) manage_traffic_cron ;;
            3) if [ -f "$TRAFFIC_LOG_FILE" ]; then echo "查看日志: $TRAFFIC_LOG_FILE (Ctrl+C 退出)"; tail -f "$TRAFFIC_LOG_FILE"; else echo "日志文件 '$TRAFFIC_LOG_FILE' 不存在。"; read -p "按回车继续..."; fi ;;
            4) echo -e "\n  \033[1m帮助说明:\033[0m"; echo "  - 此功能配置和管理内置的流量监控任务。"; echo "  - 配置保存在 $TRAFFIC_CONFIG_FILE。"; echo "  - 启用监控后，使用选项 2 设置 Cron 定时执行检查任务。"; echo "  - 日志文件位于 $TRAFFIC_LOG_FILE。"; echo "  - SSH 端口用于流量超限时限制网络，请确保其正确。"; read -p "按回车继续...";;
            5) return 0 ;;
            *) echo "无效选项"; read -p "按回车继续...";;
        esac
    done
}