#!/bin/bash
# lib_install.sh - Installation and optimize script generation

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
# Assume SCRIPT_PATH, LOG_FILE, CURRENT_VERSION, SCRIPT_DIR are exported from main
# shellcheck source=./lib_utils.sh
source "$SCRIPT_DIR/lib_utils.sh" # For log, manage_cron
# shellcheck source=./lib_config.sh
source "$SCRIPT_DIR/lib_config.sh" # For create_optimize_config

# --- Functions ---

setup_main_logrotate() {
    local logrotate_conf="/etc/logrotate.d/setup_optimize_server_main"
    log "配置主脚本日志轮转: $logrotate_conf"
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
    if [ $? -eq 0 ]; then log "主脚本日志轮转配置成功"; else log "错误: 写入主脚本logrotate配置失败"; fi
}

install_script() {
  echo -e "\033[36m▶ 开始安装/更新优化脚本 (v$CURRENT_VERSION)...\033[0m"
  local day hour template_file generated_script_content exit_code
  while true; do read -p "每周运行天数(0-6, *=每天): " day; read -p "运行小时(0-23): " hour; if [[ ( "$day" =~ ^[0-6]$ || "$day" == "*" ) && "$hour" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then break; else echo "输入无效"; fi; done

  if ! touch "$LOG_FILE" 2>/dev/null; then LOG_FILE="/tmp/setup_optimize_server.log"; echo "警告:无法写入 $LOG_FILE, 日志将保存到 $LOG_FILE" >&2; if ! touch "$LOG_FILE" 2>/dev/null; then echo "错误:无法写入日志文件"; return 1; fi; fi
  chmod 644 "$LOG_FILE"; log "脚本安装/更新开始"

  template_file="$SCRIPT_DIR/optimize_server.sh.tpl"
  if [ ! -f "$template_file" ]; then log "错误:模板 $template_file 未找到!"; echo "模板文件缺失!"; return 1; fi

  create_optimize_config || return 1

  local escaped_log_file; escaped_log_file=$(echo "$LOG_FILE" | sed 's/[\/&]/\\&/g') # Escape for sed
  generated_script_content=$(sed -e "s|__LOG_FILE__|$escaped_log_file|g" -e "s|__CURRENT_VERSION__|$CURRENT_VERSION|g" "$template_file") || { log "错误:sed替换模板失败"; echo "处理模板失败"; return 1; }

  if ! echo "$generated_script_content" | grep -q "LOG_FILE=" ; then log "错误:替换模板变量失败"; echo "处理模板失败"; return 1; fi

  echo "$generated_script_content" > "$SCRIPT_PATH"
  if [ $? -ne 0 ]; then log "错误:写入优化脚本失败"; echo "写入脚本失败"; return 1; fi

  chmod +x "$SCRIPT_PATH" || { log "错误:设置权限失败"; return 1; }
  manage_cron "$hour" "$day" || { log "错误:设置Cron失败"; return 1; }
  setup_main_logrotate # Setup logrotate for main log

  echo -e "\033[36m▶ 正在执行初始化测试...\033[0m"
  if timeout 60s bash "$SCRIPT_PATH"; then
      sleep 1; if tail -n 10 "$LOG_FILE" | grep -q "=== 优化任务结束 ==="; then echo -e "\033[32m✔ 安装/更新成功并通过测试。\033[0m"; log "安装/更新验证成功"; return 0;
      else echo -e "\033[31m✗ 测试未完成(无结束标记), 检查日志 $LOG_FILE。\033[0m"; tail -n 20 "$LOG_FILE" >&2; log "测试失败(无结束标记)"; return 1; fi
  else
    exit_code=$?; if [ $exit_code -eq 124 ]; then echo -e "\033[31m✗ 测试执行超时(60s)。\033[0m"; log "测试执行超时";
    else echo -e "\033[31m✗ 测试执行失败(码 $exit_code), 检查日志 $LOG_FILE。\033[0m"; log "测试执行失败(码 $exit_code)"; fi
    tail -n 20 "$LOG_FILE" >&2; return 1;
  fi
}