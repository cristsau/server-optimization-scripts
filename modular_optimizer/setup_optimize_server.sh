#!/bin/bash
# 脚本名称：cristsau_modular_optimizer
# 作者：cristsau
# 版本：1.0 (模块化重构)
# 功能：服务器优化管理工具 (模块化版本)

# --- Robustness Settings ---
set -uo pipefail

# --- Global Variables ---
SCRIPT_NAME="optimize_server.sh" # 生成的优化脚本名称
SCRIPT_PATH="/usr/local/bin/$SCRIPT_NAME"
LOG_FILE="/var/log/optimize_server.log" # 主日志文件路径
TEMP_LOG="/tmp/optimize_temp.log"
CURRENT_VERSION="1.0" # <-- 版本更新
BACKUP_CRON="/etc/cron.d/backup_cron" # 备份cron文件
CONFIG_FILE="/etc/backup.conf" # 备份配置文件
OPTIMIZE_CONFIG_FILE="/etc/optimize.conf" # 优化配置文件
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )" # 获取当前脚本所在目录
# Export variables needed by sourced scripts
export SCRIPT_PATH LOG_FILE TEMP_LOG CURRENT_VERSION BACKUP_CRON CONFIG_FILE OPTIMIZE_CONFIG_FILE SCRIPT_DIR

# --- Source Libraries ---
LIBS=("lib_utils.sh" "lib_config.sh" "lib_install.sh" "lib_status.sh" "lib_backup.sh" "lib_toolbox.sh" "lib_update_uninstall.sh")
for lib in "${LIBS[@]}"; do
    if [ -f "$SCRIPT_DIR/$lib" ]; then
        # shellcheck source=./lib_utils.sh
        # shellcheck source=./lib_config.sh
        # shellcheck source=./lib_install.sh
        # shellcheck source=./lib_status.sh
        # shellcheck source=./lib_backup.sh
        # shellcheck source=./lib_toolbox.sh
        # shellcheck source=./lib_update_uninstall.sh
        source "$SCRIPT_DIR/$lib"
    else
        echo "错误: 库文件 $SCRIPT_DIR/$lib 未找到!"
        exit 1
    fi
done

# --- Initial Checks ---
if [ "$(id -u)" -ne 0 ]; then echo -e "\033[31m✗ 请使用 root 权限运行\033[0m"; exit 1; fi
check_main_dependencies # Function from lib_utils.sh
# setup_main_logrotate is called within install_script now

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
  echo " 2) 👀 监控日志"
  echo " 3) 📊 查看状态"
  echo " 4) ▶️  手动执行优化"
  echo " 5) 🔗 创建快捷命令"
  echo " 6) 🛠️  工具箱"
  echo " 7) 🔄 更新本脚本"
  echo " 8) 🗑️  完全卸载"
  echo " 9) 🚪 退出"
  echo -e "\033[0m"
}

# --- Main Loop ---
while true; do
  show_menu
  read -p "请输入选项 (1-9): " choice
  case $choice in
    1) install_script ;;      # From lib_install.sh
    2) if [ -f "$LOG_FILE" ]; then echo "监控日志 (Ctrl+C 退出)"; tail -f "$LOG_FILE"; else echo "日志不存在"; fi ;;
    3) view_status ;;         # From lib_status.sh
    4) if [ -x "$SCRIPT_PATH" ]; then echo "执行 $SCRIPT_PATH ..."; "$SCRIPT_PATH"; echo "执行完成。"; else echo "脚本未安装"; fi ;;
    5) install_alias ;;      # From lib_update_uninstall.sh
    6) toolbox_menu ;;       # From lib_toolbox.sh
    7) update_from_github ;; # From lib_update_uninstall.sh
    8) uninstall ;;          # From lib_update_uninstall.sh
    9) echo "退出脚本。"; exit 0 ;;
    *) echo "无效选项";;
  esac
   if [[ "$choice" != "2" && "$choice" != "9" && "$choice" != "8" && "$choice" != "7" ]]; then
       read -p "按回车返回主菜单..."
   fi
done
