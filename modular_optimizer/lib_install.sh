#!/bin/bash
# lib_install.sh - Installation and optimize script generation (v1.3 - Add traffic wrapper generation and threshold config)

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
source "$SCRIPT_DIR/lib_utils.sh"
source "$SCRIPT_DIR/lib_config.sh"
source "$SCRIPT_DIR/lib_traffic_config.sh"

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
    if [ $? -ne 0 ]; then log "错误: 写入主脚本logrotate配置失败"; return 1; fi
    log "主脚本日志轮转配置成功"; return 0
}

generate_traffic_wrapper_script() {
    load_traffic_config > /dev/null 2>&1 || true
    if [[ "$ENABLE_TRAFFIC_MONITOR" != "true" ]]; then
        log "流量监控未启用，跳过生成包装脚本。"
        if [ -f "$TRAFFIC_WRAPPER_SCRIPT" ]; then
            rm -f "$TRAFFIC_WRAPPER_SCRIPT" && log "已移除旧的流量监控包装脚本: $TRAFFIC_WRAPPER_SCRIPT"
        fi
        return 0
    fi

    local abs_script_dir
    abs_script_dir=$(readlink -f "$SCRIPT_DIR") || { log "错误: 无法获取库文件绝对路径"; return 1; }
    local utils_lib_abs="$abs_script_dir/lib_utils.sh"
    local traffic_lib_abs="$abs_script_dir/lib_traffic_config.sh"

    log "生成流量监控包装脚本: $TRAFFIC_WRAPPER_SCRIPT"
    cat > "$TRAFFIC_WRAPPER_SCRIPT" <<EOF
#!/bin/bash
# Wrapper script to run the internal traffic monitor check.

UTILS_LIB="$utils_lib_abs"
TRAFFIC_LIB="$traffic_lib_abs"
SCRIPT_DIR="$abs_script_dir"

export LOG_FILE="$LOG_FILE"
export TRAFFIC_CONFIG_FILE="$TRAFFIC_CONFIG_FILE"
export TRAFFIC_LOG_FILE="$TRAFFIC_LOG_FILE"
export SCRIPT_DIR

set -uo pipefail

if [ -f "\$UTILS_LIB" ]; then
    source "\$UTILS_LIB"
else
    echo "Error: Cannot find utils library \$UTILS_LIB" >&2
    exit 1
fi
if [ -f "\$TRAFFIC_LIB" ]; then
    source "\$TRAFFIC_LIB"
else
    log "Error: Cannot find traffic library \$TRAFFIC_LIB"
    exit 1
fi

run_traffic_monitor_check

exit \$?
EOF
    if [ $? -ne 0 ]; then log "错误: 写入流量监控包装脚本失败"; echo "错误: 写入流量监控包装脚本失败"; return 1; fi
    chmod +x "$TRAFFIC_WRAPPER_SCRIPT" || { log "错误: 设置包装脚本权限失败"; echo "错误: 设置包装脚本权限失败"; return 1; }
    log "流量监控包装脚本生成成功: $TRAFFIC_WRAPPER_SCRIPT"
    return 0
}

install_script() {
    echo -e "\033[36m▶ 开始安装/更新优化脚本 (v$CURRENT_VERSION)...\033[0m"
    local day hour template_file exit_code escaped_log_file
    while true; do 
        read -p "每周运行天数(0-6, *=每天): " day
        read -p "运行小时(0-23): " hour
        if [[ ( "$day" =~ ^[0-6]$ || "$day" == "*" ) && "$hour" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then 
            break
        else 
            echo "输入无效"
        fi
    done

    if ! touch "$LOG_FILE" 2>/dev/null; then 
        LOG_FILE="/tmp/setup_optimize_server.log"
        echo "警告:无法写入 $LOG_FILE, 日志将保存到 $LOG_FILE" >&2
        if ! touch "$LOG_FILE" 2>/dev/null; then 
            echo "错误:无法写入日志文件"
            return 1
        fi
    fi
    chmod 644 "$LOG_FILE" 2>/dev/null || log "警告:无法设置 $LOG_FILE 权限"
    log "脚本安装/更新开始"

    template_file="$SCRIPT_DIR/optimize_server.sh.tpl"
    if [ ! -f "$template_file" ]; then 
        log "错误:模板 $template_file 未找到!"
        echo "模板文件缺失!"
        return 1
    fi

    create_optimize_config || return 1

    escaped_log_file=$(printf '%q' "$LOG_FILE")
    log "生成 $SCRIPT_PATH ..."
    sed -e "s|__LOG_FILE__|$escaped_log_file|g" -e "s|__CURRENT_VERSION__|$CURRENT_VERSION|g" "$template_file" > "$SCRIPT_PATH"
    if [ $? -ne 0 ]; then 
        log "错误:生成或写入优化脚本 $SCRIPT_PATH 失败。"
        echo "生成或写入脚本失败"
        rm -f "$SCRIPT_PATH" 2>/dev/null
        return 1
    fi
    if [ ! -s "$SCRIPT_PATH" ] || ! grep -q "LOG_FILE=" "$SCRIPT_PATH"; then 
        log "错误:生成的脚本为空或替换失败 $SCRIPT_PATH"
        echo "生成的脚本为空或替换失败"
        rm -f "$SCRIPT_PATH" 2>/dev/null
        return 1
    fi

    log "检查生成脚本 $SCRIPT_PATH 的语法..."
    if ! bash -n "$SCRIPT_PATH"; then 
        log "错误:生成的脚本 $SCRIPT_PATH 包含语法错误"
        echo -e "\033[31m生成的优化脚本包含语法错误，请检查模板 $template_file\033[0m"
        return 1
    else 
        log "生成脚本语法检查通过。"
    fi

    chmod +x "$SCRIPT_PATH" || { log "错误:设置权限失败"; return 1; }
    manage_cron "$hour" "$day" || { log "错误:设置Cron失败"; return 1; }
    setup_main_logrotate || { log "错误:配置主脚本日志轮转失败"; return 1; }

    # 配置流量监控和阈值提醒
    echo ""
    read -p "是否现在配置流量监控功能? (y/N): " configure_traffic_now
    if [[ "$configure_traffic_now" == "y" || "$configure_traffic_now" == "Y" ]]; then
        if configure_traffic_monitor && generate_traffic_wrapper_script && manage_traffic_cron; then
            echo "流量监控配置、包装脚本生成和计划任务设置完成。"
            log "流量监控配置、包装脚本生成和计划任务设置完成"
        else
            log "错误: 流量监控设置过程中遇到问题。"
            echo -e "\033[31m流量监控设置过程中遇到错误，请稍后在工具箱中重试。\033[0m"
        fi
    else
        load_traffic_config > /dev/null 2>&1 || true
        if [[ "$ENABLE_TRAFFIC_MONITOR" == "true" ]]; then
            generate_traffic_wrapper_script || log "警告: 即使监控已启用，生成包装脚本失败"
        fi
    fi

    echo -e "\033[36m▶ 正在执行优化脚本初始化测试...\033[0m"
    if timeout 120s bash "$SCRIPT_PATH"; then
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
            echo -e "\033[31m✗ 测试执行超时(120s)。\033[0m"
            log "测试执行超时"
        else 
            echo -e "\033[31m✗ 测试执行失败(码 $exit_code), 检查日志 $LOG_FILE。\033[0m"
            log "测试执行失败(码 $exit_code)"
        fi
        tail -n 20 "$LOG_FILE" >&2
        return 1
    fi
}