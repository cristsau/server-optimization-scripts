#!/bin/bash
# lib_install.sh - Installation and optimize script generation (v1.2 - Fix script generation)

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
# Assume SCRIPT_PATH, LOG_FILE, CURRENT_VERSION, SCRIPT_DIR, OPTIMIZE_CONFIG_FILE are exported from main
# shellcheck source=./lib_utils.sh
source "$SCRIPT_DIR/lib_utils.sh" # For log, manage_cron
# shellcheck source=./lib_config.sh
source "$SCRIPT_DIR/lib_config.sh" # For create_optimize_config

# --- Functions ---

setup_main_logrotate() {
    local logrotate_conf="/etc/logrotate.d/setup_optimize_server_main"
    log "配置主脚本日志轮转: $logrotate_conf"
    # Use cat > file <<EOF structure
    cat > "$logrotate_conf" <<EOF
$LOG_FILE {
    rotate 4
    weekly
    size 10M
    missingok
    notifempty
    delaycompress
    compress
    copytruncate
}
EOF
    # --- End of Heredoc ---
    if [ $? -eq 0 ]; then 
        log "主脚本日志轮转配置成功"
    else 
        log "错误: 写入主脚本logrotate配置失败"
    fi
}

generate_traffic_monitor_script() {
    local TELEGRAM_BOT_TOKEN="$1"
    local CHAT_ID="$2"
    local LIMIT_GB="$3"
    local RESET_DAY="$4"
    local SSH_PORT="$5"
    local ACTION="$6"
    local script_path="/usr/local/bin/traffic_monitor.sh"

    log "生成流量监控脚本: $script_path"
    cat > "$script_path" <<EOF
#!/bin/bash

# --- 配置部分 ---
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
CHAT_ID="$CHAT_ID"
LIMIT_GB=$LIMIT_GB
RESET_DAY=$RESET_DAY
SSH_PORT=$SSH_PORT

# --- 文件路径 ---
LOG_FILE="/root/log/traffic_monitor.log"
DAILY_REPORT_SENT_FLAG="/tmp/daily_report_sent"
LIMIT_80_PERCENT_FLAG="/tmp/vnstat_80_percent"
LIMIT_90_PERCENT_FLAG="/tmp/vnstat_90_percent"
VNSTAT_RESET_FLAG="/tmp/vnstat_reset"

# --- 初始化和函数定义 ---
mkdir -p "\$(dirname "\$LOG_FILE")"

log_time() {
  date +"%Y-%m-%d %H:%M:%S"
}

send_to_telegram() {
  local message="\$1"
  curl -s -X POST "https://api.telegram.org/bot\$TELEGRAM_BOT_TOKEN/sendMessage" \\
    -d chat_id="\$CHAT_ID" \\
    -d text="\$message" \\
    -d parse_mode="Markdown"
  if [ \$? -ne 0 ]; then
    echo "\$(log_time) ERROR: Failed to send message to Telegram." >> "\$LOG_FILE"
  fi
}

log_message() {
  echo "\$(log_time) \$1" >> "\$LOG_FILE"
}

# --- 主要逻辑开始 ---
log_message "--- Script execution started ---"

INTERFACE=\$(ip route | grep default | awk '{print \$5}' | head -n 1)
if [ -z "\$INTERFACE" ]; then
  log_message "ERROR: Could not detect network interface."
  send_to_telegram "\$(log_time) 流量监控脚本错误：无法检测到网络接口。"
  exit 1
fi
log_message "Monitoring network interface: \$INTERFACE"

LIMIT_MIB=\$(echo "\$LIMIT_GB * 1024" | bc)
LIMIT_80_PERCENT_MIB=\$(echo "\$LIMIT_MIB * 0.8" | bc)
LIMIT_90_PERCENT_MIB=\$(echo "\$LIMIT_MIB * 0.9" | bc)

log_message "Traffic limit set to: \$LIMIT_GB GB (\$LIMIT_MIB MiB)"
log_message "80% threshold: \$LIMIT_80_PERCENT_MIB MiB"
log_message "90% threshold: \$LIMIT_90_PERCENT_MIB MiB"
log_message "Traffic resets on day \$RESET_DAY of each month."

# --- 检查是否需要重置流量 ---
CURRENT_DAY=\$(date +'%-d')
LAST_DAY_OF_MONTH=\$(date -d "\$(date +'%Y%m01') +1 month -1 day" +%d)

IS_RESET_DAY=false
if [ "\$CURRENT_DAY" -eq "\$RESET_DAY" ]; then
  IS_RESET_DAY=true
elif [ "\$RESET_DAY" -gt "\$LAST_DAY_OF_MONTH" ] && [ "\$CURRENT_DAY" -eq "\$LAST_DAY_OF_MONTH" ]; then
  IS_RESET_DAY=true
fi

if \$IS_RESET_DAY; then
  if [ ! -f "\$VNSTAT_RESET_FLAG" ]; then
    log_message "Reset day detected. Attempting to reset traffic data for \$INTERFACE..."
    sudo vnstat --delete --force -i "\$INTERFACE"
    if [ \$? -eq 0 ]; then
        log_message "vnstat data deleted successfully for \$INTERFACE."
        sudo systemctl restart vnstat
        if [ \$? -eq 0 ]; then
           log_message "vnstat service restarted successfully."
           rm -f "\$LIMIT_80_PERCENT_FLAG" "\$LIMIT_90_PERCENT_FLAG"
           touch "\$VNSTAT_RESET_FLAG"
        else
           log_message "ERROR: Failed to restart vnstat service."
           send_to_telegram "\$(log_time) 流量监控脚本错误：重启 vnstat 服务失败。"
        fi
    else
        log_message "ERROR: Failed to delete vnstat data."
        send_to_telegram "\$(log_time) 流量监控脚本错误：重置流量失败。"
    fi
  fi
else
  if [ -f "\$VNSTAT_RESET_FLAG" ]; then
    rm -f "\$VNSTAT_RESET_FLAG"
  fi
fi

# --- 获取当前月度流量数据 ---
DATA=\$(vnstat -i "\$INTERFACE" --oneline)
if [ \$? -ne 0 ]; then
    log_message "ERROR: vnstat command failed."
    send_to_telegram "\$(log_time) 流量监控脚本错误：获取流量数据失败。"
    exit 1
fi

CURRENT_MONTH=\$(echo "\$DATA" | cut -d ';' -f 8)
TRAFFIC_RX_MIB=\$(echo "\$DATA" | cut -d ';' -f 9 | tr -d ' ' | sed 's/GiB/*1024/;s/TiB/*1024*1024/;s/MiB//;s/KiB/\/1024/' | bc -l)
TRAFFIC_TX_MIB=\$(echo "\$DATA" | cut -d ';' -f 10 | tr -d ' ' | sed 's/GiB/*1024/;s/TiB/*1024*1024/;s/MiB//;s/KiB/\/1024/' | bc -l)
TRAFFIC_RX_MIB=\${TRAFFIC_RX_MIB:-0}
TRAFFIC_TX_MIB=\${TRAFFIC_TX_MIB:-0}
TRAFFIC_TO_CHECK_MIB=\$(echo "\$TRAFFIC_TX_MIB \$TRAFFIC_RX_MIB" | awk '{if (\$1+0 > \$2+0) print \$1; else print \$2}')

log_message "Current month (\$CURRENT_MONTH) usage: RX = \$TRAFFIC_RX_MIB MiB, TX = \$TRAFFIC_TX_MIB MiB"
log_message "Traffic to check: \$TRAFFIC_TO_CHECK_MIB MiB"

# --- 检查并发送警告 ---
if [ "\$LIMIT_GB" -ne 0 ]; then
  if (( \$(echo "\$TRAFFIC_TO_CHECK_MIB > \$LIMIT_80_PERCENT_MIB" | bc -l) )); then
    if [ ! -f "\$LIMIT_80_PERCENT_FLAG" ]; then
      usage_percent=\$(echo "scale=2; (\$TRAFFIC_TO_CHECK_MIB / \$LIMIT_MIB) * 100" | bc)
      send_to_telegram "\$(log_time) 警告: 月度流量已使用 \$TRAFFIC_TO_CHECK_MIB MiB (\$usage_percent%), 超过 80% 阈值。"
      touch "\$LIMIT_80_PERCENT_FLAG"
    fi
  fi
  if (( \$(echo "\$TRAFFIC_TO_CHECK_MIB > \$LIMIT_90_PERCENT_MIB" | bc -l) )); then
    if [ ! -f "\$LIMIT_90_PERCENT_FLAG" ]; then
      usage_percent=\$(echo "scale=2; (\$TRAFFIC_TO_CHECK_MIB / \$LIMIT_MIB) * 100" | bc)
      send_to_telegram "\$(log_time) 严重警告: 月度流量已使用 \$TRAFFIC_TO_CHECK_MIB MiB (\$usage_percent%), 超过 90% 阈值。"
      touch "\$LIMIT_90_PERCENT_FLAG"
    fi
  fi
fi

# --- 每日报告 ---
current_hour=\$(date +%H)
current_minute=\$(date +%M)
if [ "\$current_hour" -eq 10 ] && [ "\$current_minute" -lt 5 ] && [ ! -f "\$DAILY_REPORT_SENT_FLAG" ]; then
  REPORT_MAX_MIB=\$TRAFFIC_TO_CHECK_MIB
  REPORT_MAX_GB=\$(echo "scale=1; \$REPORT_MAX_MIB / 1024" | bc)
  REMAINING_LIMIT_MIB=\$(echo "\$LIMIT_MIB - \$REPORT_MAX_MIB" | bc)
  if (( \$(echo "\$REMAINING_LIMIT_MIB < 0" | bc -l) )); then REMAINING_LIMIT_MIB=0; fi
  REMAINING_LIMIT_GB=\$(echo "scale=1; \$REMAINING_LIMIT_MIB / 1024" | bc)
  send_to_telegram "\$(log_time) 服务器流量报告\n已用总量: \$REPORT_MAX_GB GB / \$LIMIT_GB GB\n剩余可用: \$REMAINING_LIMIT_GB GB"
  touch "\$DAILY_REPORT_SENT_FLAG"
elif [ -f "\$DAILY_REPORT_SENT_FLAG" ] && [ "\$current_hour" -ne 10 ]; then
  rm -f "\$DAILY_REPORT_SENT_FLAG"
fi

# --- 超限操作 ---
if [ "\$LIMIT_GB" -ne 0 ] && (( \$(echo "\$TRAFFIC_TO_CHECK_MIB > \$LIMIT_MIB" | bc -l) )); then
  case "$ACTION" in
    "shutdown")
      send_to_telegram "\$(log_time) 警告：流量超限，将关机！"
      shutdown now
      ;;
    "limit")
      send_to_telegram "\$(log_time) 警告：流量超限，限制网络，仅保留 SSH (端口 \$SSH_PORT)。"
      iptables -F
      iptables -X
      iptables -t nat -F
      iptables -t nat -X
      iptables -t mangle -F
      iptables -t mangle -X
      iptables -P INPUT DROP
      iptables -P FORWARD DROP
      iptables -P OUTPUT ACCEPT
      iptables -A INPUT -i lo -j ACCEPT
      iptables -A OUTPUT -o lo -j ACCEPT
      iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
      iptables -A INPUT -p tcp --dport \$SSH_PORT -j ACCEPT
      if command -v ip6tables &> /dev/null; then
        ip6tables -F
        ip6tables -X
        ip6tables -t mangle -F
        ip6tables -t mangle -X
        ip6tables -P INPUT DROP
        ip6tables -P FORWARD DROP
        ip6tables -P OUTPUT ACCEPT
        ip6tables -A INPUT -i lo -j ACCEPT
        ip6tables -A OUTPUT -o lo -j ACCEPT
        ip6tables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
        ip6tables -A INPUT -p tcp --dport \$SSH_PORT -j ACCEPT
      fi
      ;;
    "none")
      log_message "Traffic limit exceeded, no action taken."
      ;;
  esac
elif [ "\$LIMIT_GB" -ne 0 ]; then
  if ! iptables -L INPUT | grep -q "policy ACCEPT"; then
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
  fi
  if command -v ip6tables &> /dev/null; then
    if ! ip6tables -L INPUT | grep -q "policy ACCEPT"; then
      ip6tables -P INPUT ACCEPT
      ip6tables -P FORWARD ACCEPT
      ip6tables -P OUTPUT ACCEPT
      ip6tables -F
      ip6tables -t mangle -F
    fi
  fi
fi

log_message "--- Script execution finished ---"
exit 0
EOF

    chmod +x "$script_path"
    log "流量监控脚本已生成并配置完成，路径：$script_path"
    echo "流量监控脚本已生成并配置完成，路径：$script_path"
}

install_script() {
    echo -e "\033[36m▶ 开始安装/更新优化脚本 (v$CURRENT_VERSION)...\033[0m"
    local day hour template_file exit_code escaped_log_file

    # 交互式输入：每周运行天数和小时
    while true; do 
        read -p "每周运行天数(0-6, *=每天): " day
        read -p "运行小时(0-23): " hour
        if [[ ( "$day" =~ ^[0-6]$ || "$day" == "*" ) && "$hour" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then 
            break
        else 
            echo "输入无效"
        fi
    done

    # 检查日志文件可写性
    if ! touch "$LOG_FILE" 2>/dev/null; then 
        LOG_FILE="/tmp/setup_optimize_server.log"
        echo "警告: 无法写入 $LOG_FILE, 日志将保存到 $LOG_FILE" >&2
        if ! touch "$LOG_FILE" 2>/dev/null; then 
            echo "错误: 无法写入日志文件"
            return 1
        fi
    fi
    chmod 644 "$LOG_FILE" 2>/dev/null || log "警告: 无法设置 $LOG_FILE 权限"
    log "脚本安装/更新开始"

    # 检查模板文件
    template_file="$SCRIPT_DIR/optimize_server.sh.tpl"
    if [ ! -f "$template_file" ]; then 
        log "错误: 模板 $template_file 未找到!"
        echo "模板文件缺失!"
        return 1
    fi

    # 创建优化配置文件
    create_optimize_config || return 1 # from lib_config.sh

    # 生成优化脚本
    escaped_log_file=$(echo "$LOG_FILE" | sed 's/[\/&]/\\&/g') # Escape for sed
    log "生成 $SCRIPT_PATH ..."
    sed -e "s|__LOG_FILE__|$escaped_log_file|g" -e "s|__CURRENT_VERSION__|$CURRENT_VERSION|g" "$template_file" > "$SCRIPT_PATH"
    if [ $? -ne 0 ]; then
        log "错误: 生成或写入优化脚本 $SCRIPT_PATH 失败。"
        echo "生成或写入脚本失败"
        rm -f "$SCRIPT_PATH" 2>/dev/null
        return 1
    fi

    # 检查生成的文件
    if [ ! -s "$SCRIPT_PATH" ] || ! grep -q "LOG_FILE=" "$SCRIPT_PATH"; then
        log "错误: 生成的脚本为空或替换失败 $SCRIPT_PATH"
        echo "生成的脚本为空或替换失败"
        rm -f "$SCRIPT_PATH" 2>/dev/null
        return 1
    fi

    # 验证脚本语法
    log "检查生成脚本 $SCRIPT_PATH 的语法..."
    if ! bash -n "$SCRIPT_PATH"; then
        log "错误: 生成的脚本 $SCRIPT_PATH 包含语法错误"
        echo -e "\033[31m生成的优化脚本包含语法错误，请检查模板 $template_file\033[0m"
        return 1
    else
        log "生成脚本语法检查通过。"
    fi

    # 设置权限和计划任务
    chmod +x "$SCRIPT_PATH" || { log "错误: 设置权限失败"; return 1; }
    manage_cron "$hour" "$day" || { log "错误: 设置Cron失败"; return 1; } # from lib_utils.sh
    setup_main_logrotate || { log "错误: 配置主脚本日志轮转失败"; return 1; }

    # 执行初始化测试
    echo -e "\033[36m▶ 正在执行初始化测试...\033[0m"
    if timeout 60s bash "$SCRIPT_PATH"; then
        sleep 1
        if tail -n 10 "$LOG_FILE" | grep -q "=== 优化任务结束 ==="; then 
            echo -e "\033[32m✔ 安装/更新成功并通过测试。\033[0m"
            log "安装/更新验证成功"
            return 0
        else 
            echo -e "\033[31m✗ 测试未完成(无结束标记), 检查日志 $LOG_FILE。\033[0m"
            tail -n 20 "$LOG_FILE" >&2
            log "测试失败(无结束标记)"
            return 1
        fi
    else
        exit_code=$?
        if [ $exit_code -eq 124 ]; then 
            echo -e "\033[31m✗ 测试执行超时(60s)。\033[0m"
            log "测试执行超时"
        else 
            echo -e "\033[31m✗ 测试执行失败(码 $exit_code), 检查日志 $LOG_FILE。\033[0m"
            log "测试执行失败(码 $exit_code)"
        fi
        tail -n 20 "$LOG_FILE" >&2
        return 1
    fi
}