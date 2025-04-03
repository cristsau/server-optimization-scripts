#!/bin/bash
# lib_traffic_config.sh - Traffic monitoring functions (v1.3.1 - Add threshold input and reminders)

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
source "$SCRIPT_DIR/lib_utils.sh" # For log, clear_cmd, check_command, validate_numeric, get_ssh_port

# --- Functions ---
load_traffic_config() {
    log "加载流量监控配置: $TRAFFIC_CONFIG_FILE"
    ENABLE_TRAFFIC_MONITOR="false"; TELEGRAM_BOT_TOKEN=""; CHAT_ID=""; ENABLE_LIMIT="false"; LIMIT_GB=200; ENABLE_RESET="true"; RESET_DAY=1; SSH_PORT=22; OVER_LIMIT_ACTION="limit_net"; TRAFFIC_CRON_FREQ="*/5"
    THRESHOLD_1=80; THRESHOLD_2=90; THRESHOLD_3=0 # 默认阈值

    if [ -f "$TRAFFIC_CONFIG_FILE" ]; then
        source "$TRAFFIC_CONFIG_FILE" || log "警告: 加载流量监控配置 $TRAFFIC_CONFIG_FILE 时出错"
        log "已加载现有流量监控配置。"
        [[ "$ENABLE_TRAFFIC_MONITOR" != "true" ]] && ENABLE_TRAFFIC_MONITOR="false"
        [[ "$ENABLE_LIMIT" != "true" ]] && ENABLE_LIMIT="false"
        [[ "$ENABLE_RESET" != "true" ]] && ENABLE_RESET="false"
        validate_numeric "${LIMIT_GB:-200}" "Limit GB" || LIMIT_GB=200; [[ "$LIMIT_GB" -lt 0 ]] && LIMIT_GB=0
        validate_numeric "${RESET_DAY:-1}" "Reset Day" || RESET_DAY=1; [[ "$RESET_DAY" -lt 1 || "$RESET_DAY" -gt 31 ]] && RESET_DAY=1
        validate_numeric "${SSH_PORT:-22}" "SSH Port" || SSH_PORT=22
        case "$OVER_LIMIT_ACTION" in limit_net|shutdown|notify_only) ;; *) OVER_LIMIT_ACTION="limit_net";; esac
        [[ -z "$TRAFFIC_LOG_FILE" ]] && TRAFFIC_LOG_FILE="/var/log/traffic_monitor.log"
        [[ ! "$TRAFFIC_CRON_FREQ" =~ ^(\*\/[0-9]+|[0-9\*\/\,-]+)$ ]] && TRAFFIC_CRON_FREQ="*/5"
        validate_numeric "${THRESHOLD_1:-80}" "Threshold 1" || THRESHOLD_1=80; [[ "$THRESHOLD_1" -lt 0 || "$THRESHOLD_1" -gt 100 ]] && THRESHOLD_1=80
        validate_numeric "${THRESHOLD_2:-90}" "Threshold 2" || THRESHOLD_2=90; [[ "$THRESHOLD_2" -lt 0 || "$THRESHOLD_2" -gt 100 ]] && THRESHOLD_2=90
        validate_numeric "${THRESHOLD_3:-0}" "Threshold 3" || THRESHOLD_3=0; [[ "$THRESHOLD_3" -lt 0 || "$THRESHOLD_3" -gt 100 ]] && THRESHOLD_3=0
    else
        SSH_PORT=$(get_ssh_port | tail -n 1)
    fi
    export ENABLE_TRAFFIC_MONITOR TELEGRAM_BOT_TOKEN CHAT_ID ENABLE_LIMIT LIMIT_GB ENABLE_RESET RESET_DAY SSH_PORT OVER_LIMIT_ACTION TRAFFIC_LOG_FILE TRAFFIC_CRON_FREQ THRESHOLD_1 THRESHOLD_2 THRESHOLD_3
}

configure_traffic_monitor() {
    log "运行流量监控配置向导"
    check_command "vnstat" || { echo "错误: vnstat 未安装，请先安装 (apt install vnstat)"; return 1; }
    check_command "curl" || { echo "错误: curl 未安装，请先安装 (apt install curl)"; return 1; }
    check_command "bc" || { echo "错误: bc 未安装，请先安装 (apt install bc)"; return 1; }

    echo -e "\n\033[36m--- 流量监控配置向导 ---\033[0m"
    load_traffic_config

    local confirm_enable input_token input_chatid confirm_limit input_limit_gb input_reset_day action_choice input_log_path detected_ssh_port confirm_reset
    local input_threshold_1 input_threshold_2 input_threshold_3

    read -p "是否启用流量监控? (y/N) [当前: $ENABLE_TRAFFIC_MONITOR]: " confirm_enable
    ENABLE_TRAFFIC_MONITOR=$([[ "$confirm_enable" == "y" || "$confirm_enable" == "Y" ]] && echo "true" || echo "false")
    read -p "输入 Telegram Bot Token [当前: ${TELEGRAM_BOT_TOKEN:--空-}]: " input_token
    TELEGRAM_BOT_TOKEN=${input_token:-$TELEGRAM_BOT_TOKEN}
    read -p "输入 Telegram Chat ID [当前: ${CHAT_ID:--空-}]: " input_chatid
    CHAT_ID=${input_chatid:-$CHAT_ID}
    read -p "是否启用流量限制? (y/N) [当前: $ENABLE_LIMIT]: " confirm_limit
    ENABLE_LIMIT=$([[ "$confirm_limit" == "y" || "$confirm_limit" == "Y" ]] && echo "true" || echo "false")
    if [[ "$ENABLE_LIMIT" == "true" ]]; then
        read -p "输入月度流量限制 (GB) [当前: $LIMIT_GB]: " input_limit_gb
        input_limit_gb=${input_limit_gb:-$LIMIT_GB}
        if validate_numeric "$input_limit_gb" "流量限制"; then LIMIT_GB=$input_limit_gb; else echo "输入无效，保留当前值 $LIMIT_GB"; fi
        echo "设置流量使用率提醒阈值 (0-100%，0表示禁用)："
        read -p "  阈值 1 (%) [当前: $THRESHOLD_1]: " input_threshold_1
        THRESHOLD_1=${input_threshold_1:-$THRESHOLD_1}
        if validate_numeric "$THRESHOLD_1" "阈值 1" && [ "$THRESHOLD_1" -ge 0 ] && [ "$THRESHOLD_1" -le 100 ]; then :; else echo "输入无效，使用当前值"; fi
        read -p "  阈值 2 (%) [当前: $THRESHOLD_2]: " input_threshold_2
        THRESHOLD_2=${input_threshold_2:-$THRESHOLD_2}
        if validate_numeric "$THRESHOLD_2" "阈值 2" && [ "$THRESHOLD_2" -ge 0 ] && [ "$THRESHOLD_2" -le 100 ]; then :; else echo "输入无效，使用当前值"; fi
        read -p "  阈值 3 (%) [当前: $THRESHOLD_3]: " input_threshold_3
        THRESHOLD_3=${input_threshold_3:-$THRESHOLD_3}
        if validate_numeric "$THRESHOLD_3" "阈值 3" && [ "$THRESHOLD_3" -ge 0 ] && [ "$THRESHOLD_3" -le 100 ]; then :; else echo "输入无效，使用当前值"; fi
    else
        LIMIT_GB=0
        THRESHOLD_1=0; THRESHOLD_2=0; THRESHOLD_3=0
    fi
    read -p "是否启用每月流量重置? (y/N) [当前: $ENABLE_RESET]: " confirm_reset
    ENABLE_RESET=$([[ "$confirm_reset" == "y" || "$confirm_reset" == "Y" ]] && echo "true" || echo "false")
    if [[ "$ENABLE_RESET" == "true" ]]; then
        read -p "输入每月重置日 (1-31) [当前: $RESET_DAY]: " input_reset_day
        input_reset_day=${input_reset_day:-$RESET_DAY}
        if validate_numeric "$input_reset_day" "重置日" && [ "$input_reset_day" -ge 1 ] && [ "$input_reset_day" -le 31 ]; then RESET_DAY=$input_reset_day; else echo "输入无效，保留当前值 $RESET_DAY"; fi
    fi
    detected_ssh_port=$(get_ssh_port | tail -n 1)
    read -p "输入 SSH 端口 [检测到: $detected_ssh_port, 当前: $SSH_PORT]: " input_ssh_port
    SSH_PORT=${input_ssh_port:-$SSH_PORT}
    if ! validate_numeric "$SSH_PORT" "SSH 端口"; then SSH_PORT=$detected_ssh_port; echo "输入无效，使用检测值 $SSH_PORT"; fi
    echo "选择超限后的操作：1) 限制网络 (limit_net)  2) 关机 (shutdown)  3) 仅通知 (notify_only)"
    read -p "输入选项 (1-3) [当前: $OVER_LIMIT_ACTION]: " action_choice
    case "$action_choice" in
        1|"") OVER_LIMIT_ACTION="limit_net" ;;
        2) OVER_LIMIT_ACTION="shutdown" ;;
        3) OVER_LIMIT_ACTION="notify_only" ;;
        *) echo "无效选项，使用当前值 $OVER_LIMIT_ACTION" ;;
    esac
    read -p "输入流量日志路径 [当前: $TRAFFIC_LOG_FILE]: " input_log_path
    TRAFFIC_LOG_FILE=${input_log_path:-$TRAFFIC_LOG_FILE}
    read -p "输入流量检查频率 (Cron 分钟字段，如 */5 表示每5分钟) [当前: $TRAFFIC_CRON_FREQ]: " input_cron_freq
    TRAFFIC_CRON_FREQ=${input_cron_freq:-$TRAFFIC_CRON_FREQ}
    if [[ ! "$TRAFFIC_CRON_FREQ" =~ ^(\*\/[0-9]+|[0-9\*\/\,-]+)$ ]]; then TRAFFIC_CRON_FREQ="*/5"; echo "输入无效，使用默认值 */5"; fi

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
TRAFFIC_CRON_FREQ="$TRAFFIC_CRON_FREQ"
THRESHOLD_1="$THRESHOLD_1"
THRESHOLD_2="$THRESHOLD_2"
THRESHOLD_3="$THRESHOLD_3"
EOF
    chmod 600 "$TRAFFIC_CONFIG_FILE"
    log "配置已保存: $TRAFFIC_CONFIG_FILE"
    return 0
}

traffic_monitor_config_menu() {
    while true; do
        clear_cmd
        echo -e "\033[36m🚦 流量监控管理菜单\033[0m"
        echo -e "\n  \033[1m可用选项:\033[0m"
        echo "    1) 配置流量监控参数"
        echo "    2) 设置流量监控计划任务"
        echo "    3) 手动运行流量检查"
        echo "    4) 重置流量数据"
        echo "    5) 返回主菜单"
        echo -e "\033[0m"
        read -p "请输入选项 (1-5): " choice
        case $choice in
            1) configure_traffic_monitor ;;
            2) configure_traffic_cron ;;
            3) run_traffic_monitor_check ;;
            4) reset_traffic_data ;;
            5) return 0 ;;
            *) echo "无效选项" ;;
        esac
        read -p "按回车继续..."
    done
}

configure_traffic_cron() {
    log "配置流量监控计划任务"
    load_traffic_config
    if [[ "$ENABLE_TRAFFIC_MONITOR" != "true" ]]; then
        echo "流量监控未启用，请先运行 '配置流量监控参数'"
        return 1
    fi
    cat > "$TRAFFIC_WRAPPER_SCRIPT" <<EOF
#!/bin/bash
TRAFFIC_CONFIG_FILE="$TRAFFIC_CONFIG_FILE"
SCRIPT_DIR="$SCRIPT_DIR"
source "\$SCRIPT_DIR/lib_traffic_config.sh"
run_traffic_monitor_check
EOF
    chmod +x "$TRAFFIC_WRAPPER_SCRIPT"
    log "生成流量检查包装脚本: $TRAFFIC_WRAPPER_SCRIPT"
    cat > "$TRAFFIC_CRON_FILE" <<EOF
# Traffic Monitor Cron Job
# Generated: $(date)
$TRAFFIC_CRON_FREQ * * * * root $TRAFFIC_WRAPPER_SCRIPT >> $TRAFFIC_LOG_FILE 2>&1
EOF
    chmod 644 "$TRAFFIC_CRON_FILE"
    log "流量监控计划任务已配置: $TRAFFIC_CRON_FILE"
    echo "流量监控计划任务已配置，每 $TRAFFIC_CRON_FREQ 分钟检查一次"
}

reset_traffic_data() {
    log "重置流量数据"
    check_command "vnstat" || { echo "错误: vnstat 未安装"; return 1; }
    local interface=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    echo "正在重置接口 $interface 的流量数据..."
    vnstat -i "$interface" --reset
    if [ $? -eq 0 ]; then
        log "流量数据重置成功: $interface"
        echo "流量数据已重置"
    else
        log "流量数据重置失败: $interface"
        echo "流量数据重置失败"
        return 1
    fi
}

run_traffic_monitor_check() {
    log "运行流量监控检查"
    check_command "vnstat" || { log "错误: vnstat 未安装"; return 1; }
    check_command "curl" || { log "错误: curl 未安装"; return 1; }
    check_command "bc" || { log "错误: bc 未安装"; return 1; }
    load_traffic_config

    if [[ "$ENABLE_TRAFFIC_MONITOR" != "true" ]]; then
        log "流量监控未启用，跳过检查"
        return 0
    fi

    local interface=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    log "监控网络接口: $interface"
    DATA=$(vnstat -i "$interface" --oneline 2>/dev/null)
    TRAFFIC_RX_MIB=$(echo "$DATA" | cut -d ';' -f 9 | tr -d ' ' | sed 's/GiB/*1024/;s/TiB/*1024*1024/;s/MiB//;s/KiB/\/1024/' | bc -l 2>/dev/null || echo 0)
    TRAFFIC_TX_MIB=$(echo "$DATA" | cut -d ';' -f 10 | tr -d ' ' | sed 's/GiB/*1024/;s/TiB/*1024*1024/;s/MiB//;s/KiB/\/1024/' | bc -l 2>/dev/null || echo 0)
    TRAFFIC_TOTAL_MIB=$(echo "$TRAFFIC_RX_MIB + $TRAFFIC_TX_MIB" | bc)
    TRAFFIC_TOTAL_GB=$(echo "scale=2; $TRAFFIC_TOTAL_MIB / 1024" | bc)
    log "当前流量: RX=${TRAFFIC_RX_MIB} MiB, TX=${TRAFFIC_TX_MIB} MiB, Total=${TRAFFIC_TOTAL_GB} GB"

    if [[ "$ENABLE_RESET" == "true" ]]; then
        local current_day=$(date +%d)
        if [[ "$current_day" -eq "$RESET_DAY" ]]; then
            log "检测到重置日 ($RESET_DAY)，重置流量数据"
            reset_traffic_data
            TRAFFIC_TOTAL_MIB=0
            TRAFFIC_TOTAL_GB=0
        fi
    fi

    if [[ "$ENABLE_LIMIT" == "true" && "$LIMIT_GB" -gt 0 ]]; then
        LIMIT_MIB=$(echo "$LIMIT_GB * 1024" | bc)
        TRAFFIC_PERCENT=$(echo "scale=2; ($TRAFFIC_TOTAL_MIB / $LIMIT_MIB) * 100" | bc)
        log "流量限制: $LIMIT_GB GB ($LIMIT_MIB MiB), 使用率: $TRAFFIC_PERCENT%"

        # 阈值提醒
        if (( $(echo "$TRAFFIC_PERCENT > $THRESHOLD_1" | bc -l) )) && [ "$THRESHOLD_1" -gt 0 ]; then
            send_telegram_notification "⚠️ 流量使用率达到 $TRAFFIC_PERCENT%，超过阈值 1 ($THRESHOLD_1%)，当前使用 $TRAFFIC_TOTAL_GB GB / $LIMIT_GB GB"
            log "流量超过阈值 1 ($THRESHOLD_1%)"
        fi
        if (( $(echo "$TRAFFIC_PERCENT > $THRESHOLD_2" | bc -l) )) && [ "$THRESHOLD_2" -gt 0 ]; then
            send_telegram_notification "⚠️ 流量使用率达到 $TRAFFIC_PERCENT%，超过阈值 2 ($THRESHOLD_2%)，当前使用 $TRAFFIC_TOTAL_GB GB / $LIMIT_GB GB"
            log "流量超过阈值 2 ($THRESHOLD_2%)"
        fi
        if (( $(echo "$TRAFFIC_PERCENT > $THRESHOLD_3" | bc -l) )) && [ "$THRESHOLD_3" -gt 0 ]; then
            send_telegram_notification "⚠️ 流量使用率达到 $TRAFFIC_PERCENT%，超过阈值 3 ($THRESHOLD_3%)，当前使用 $TRAFFIC_TOTAL_GB GB / $LIMIT_GB GB"
            log "流量超过阈值 3 ($THRESHOLD_3%)"
        fi

        if (( $(echo "$TRAFFIC_TOTAL_MIB > $LIMIT_MIB" | bc -l) )); then
            log "流量超限: $TRAFFIC_TOTAL_GB GB 超过 $LIMIT_GB GB"
            send_telegram_notification "❌ 流量超限！当前使用: $TRAFFIC_TOTAL_GB GB，限制: $LIMIT_GB GB"
            case "$OVER_LIMIT_ACTION" in
                "limit_net")
                    log "执行网络限制操作"
                    iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
                    iptables -A OUTPUT -p tcp --sport "$SSH_PORT" -j ACCEPT
                    iptables -A INPUT -j DROP
                    iptables -A OUTPUT -j DROP
                    log "网络已限制，仅保留 SSH 端口 $SSH_PORT"
                    ;;
                "shutdown")
                    log "执行关机操作"
                    send_telegram_notification "服务器即将因流量超限而关机"
                    shutdown -h now
                    ;;
                "notify_only")
                    log "仅通知，无操作"
                    ;;
            esac
        fi
    fi
    log "流量检查完成"
    return 0
}

send_telegram_notification() {
    local message="$1"
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        log "Telegram 配置缺失，无法发送通知"
        return 1
    fi
    local url="https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage"
    curl -s -X POST "$url" -d chat_id="$CHAT_ID" -d text="$message" >/dev/null
    if [ $? -eq 0 ]; then
        log "Telegram 通知发送成功: $message"
    else
        log "Telegram 通知发送失败: $message"
    fi
}