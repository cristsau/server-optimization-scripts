#!/bin/bash
# 脚本名称：cristsau_modular_optimizer
# 作者：cristsau
# 版本：1.3.1 (修复 toolbox_menu, 添加流量阈值输入和提醒)
# 功能：服务器优化管理工具 (模块化版本)

# --- Robustness Settings ---
set -uo pipefail

# --- Global Variables ---
SCRIPT_NAME="optimize_server.sh"
SCRIPT_PATH="/usr/local/bin/$SCRIPT_NAME"
LOG_FILE="/var/log/optimize_server.log"
TEMP_LOG="/tmp/optimize_temp.log"
CURRENT_VERSION="1.3.1"
BACKUP_CRON="/etc/cron.d/backup_tasks"
CONFIG_FILE="/etc/backup.conf"
OPTIMIZE_CONFIG_FILE="/etc/optimize.conf"
TRAFFIC_CONFIG_FILE="/etc/traffic_monitor.conf"
TRAFFIC_CRON_FILE="/etc/cron.d/traffic_monitor_cron"
TRAFFIC_WRAPPER_SCRIPT="/usr/local/bin/run_traffic_check_wrapper.sh"
TRAFFIC_LOG_FILE="/var/log/traffic_monitor.log"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
export SCRIPT_PATH LOG_FILE TEMP_LOG CURRENT_VERSION BACKUP_CRON CONFIG_FILE OPTIMIZE_CONFIG_FILE SCRIPT_DIR TRAFFIC_CONFIG_FILE TRAFFIC_CRON_FILE TRAFFIC_WRAPPER_SCRIPT TRAFFIC_LOG_FILE

# --- Source Libraries ---
LIBS=("lib_utils.sh" "lib_config.sh" "lib_traffic_config.sh" "lib_install.sh" "lib_status.sh" "lib_backup.sh" "lib_toolbox.sh" "lib_update_uninstall.sh")
for lib in "${LIBS[@]}"; do
    if [ -f "$SCRIPT_DIR/$lib" ]; then
        source "$SCRIPT_DIR/$lib"
        echo "已加载: $lib" # 添加调试信息
    else
        echo "错误: 库文件 $SCRIPT_DIR/$lib 未找到!"
        exit 1
    fi
done
# 验证 toolbox_menu 是否加载
if declare -f toolbox_menu >/dev/null; then
    echo "toolbox_menu 函数已定义"
else
    echo "错误: toolbox_menu 函数未定义"
    exit 1
fi

# --- Initial Checks ---
if [ "$(id -u)" -ne 0 ]; then echo -e "\033[31m✗ 请使用 root 权限运行\033[0m"; exit 1; fi
check_main_dependencies

# --- Main Menu ---
show_menu() {
    clear_cmd
    local colors=("\033[31m" "\033[38;5;208m" "\033[33m" "\033[32m" "\033[34m" "\033[35m")
    local num_colors=${#colors[@]}; local color_index=0
    local logo_lines=(
"    ██████╗██████╗ ██╗███████╗████████╗███████╗ █████╗ ██╗    ██╗"
"  ██╔════╝██╔══██╗██║██╔════╝╚══██╔══╝██╔════╝██╔══██╗██║    ██║"
"  ██║     ██████╔╝██║███████╗   ██║   ███████╗███████║██║    ██║"
"  ██║     ██╔══██╗██║╚════██║   ██║   ╚════██║██╔══██║██║    ██║"
"  ╚██████╗██║  ██║██║███████║   ██║   ███████║██║  ██║╚██████╔╝"
"   ╚═════╝╚═╝  ╚═╝╚═╝╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝ ╚═════╝  "
    ); for line in "${logo_lines[@]}"; do echo -e "${colors[$color_index]}$line\033[0m"; color_index=$(( (color_index + 1) % num_colors )); done
    echo -e "\033[36m v$CURRENT_VERSION\033[0m"
    echo -e "\033[36m"
    echo " 1) 📥 安装/更新优化脚本"
    echo " 2) 👀 监控优化日志 ($LOG_FILE)"
    echo " 3) 📊 查看系统状态"
    echo " 4) ▶️  手动执行优化脚本"
    echo " 5) 🔗 创建快捷命令 (别名)"
    echo " 6) 🛠️  工具箱 (Docker/时间/BBR/备份/流量/健康检查)"
    echo " 7) 🔄 更新本工具脚本 (从 GitHub)"
    echo " 8) 🗑️  完全卸载本工具"
    echo " 9) 🚪 退出"
    echo -e "\033[0m"
}

# --- Main Loop ---
while true; do
    show_menu
    read -p "请输入选项 (1-9): " choice
    case $choice in
        1) install_script ;;
        2) if [ -f "$LOG_FILE" ]; then echo "监控日志: $LOG_FILE (Ctrl+C 退出)"; tail -f "$LOG_FILE"; else echo "日志文件 $LOG_FILE 不存在"; fi ;;
        3) view_status ;;
        4) if [ -x "$SCRIPT_PATH" ]; then echo "执行 $SCRIPT_PATH ..."; if bash "$SCRIPT_PATH"; then echo "执行完成。"; else echo "执行出错 (返回码 $?)"; fi; else echo "脚本 $SCRIPT_PATH 未安装或不可执行"; fi ;;
        5) install_alias ;;
        6) toolbox_menu ;;
        7) update_from_github ;;
        8) uninstall ;;
        9) echo "退出脚本。"; exit 0 ;;
        *) echo "无效选项";;
    esac
    if [[ "$choice" != "2" && "$choice" != "9" && "$choice" != "8" && "$choice" != "7" ]]; then
        read -p "按回车返回主菜单..."
    fi
done