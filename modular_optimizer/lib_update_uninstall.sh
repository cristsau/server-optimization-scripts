#!/bin/bash
# lib_update_uninstall.sh - Update and uninstall functions

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
# Assume global vars: CURRENT_VERSION, SCRIPT_PATH, LOG_FILE, BACKUP_CRON, CONFIG_FILE, SCRIPT_DIR are accessible
# shellcheck source=./lib_utils.sh
source "$SCRIPT_DIR/lib_utils.sh" # For log, manage_cron, check_command

# --- Functions ---
install_alias() {
   log "运行别名安装向导"
   echo -e "\033[36m▶ 快捷命令安装向导\033[0m"; local cmd current_script_path target_link;
   read -p "命令名(默认cristsau): " cmd; cmd=${cmd:-cristsau}; if ! [[ "$cmd" =~ ^[a-zA-Z0-9_-]+$ ]]; then echo "非法字符"; return 1; fi;
   current_script_path=$(readlink -f "${BASH_SOURCE[1]:-$0}") # BASH_SOURCE[1] if sourced, $0 otherwise
   if [[ ! "$current_script_path" || "$current_script_path" != *setup_optimize_server.sh ]]; then
        local script_in_path; script_in_path=$(which setup_optimize_server.sh 2>/dev/null) # Check if main script is in PATH under original name
        if [ -n "$script_in_path" ]; then current_script_path=$(readlink -f "$script_in_path");
        elif [ -f "$SCRIPT_DIR/setup_optimize_server.sh" ]; then current_script_path="$SCRIPT_DIR/setup_optimize_server.sh"; # Check script dir
        else echo "无法确定主脚本路径"; return 1; fi
   fi
   target_link="/usr/local/bin/$cmd";
   log "创建软链接 $target_link -> $current_script_path"
   ln -sf "$current_script_path" "$target_link" || { echo "创建失败"; log "创建快捷命令 $cmd 失败"; return 1; };
   chmod +x "$current_script_path" || log "警告:设置主脚本 $current_script_path 权限失败";
   echo -e "\033[32m✔ 已创建快捷命令: $cmd -> $current_script_path\033[0m"; log "创建快捷命令 $cmd";
   return 0
}

uninstall() {
   log "运行卸载程序"
   echo -e "\033[31m▶ 开始卸载...\033[0m"; local confirm target link del_log; read -p "确定完全卸载?(y/N): " confirm; if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo "取消"; return; fi;
   log "开始卸载"; echo "移除优化任务..."; manage_cron || log "移除优化cron失败";
   echo "移除备份任务..."; if [ -f "$BACKUP_CRON" ]; then rm -v "$BACKUP_CRON" && log "$BACKUP_CRON已移除" || log "移除 $BACKUP_CRON 失败"; else echo "跳过"; fi;
   echo "移除备份配置..."; if [ -f "$CONFIG_FILE" ]; then rm -v "$CONFIG_FILE" && log "$CONFIG_FILE已移除" || log "移除 $CONFIG_FILE 失败"; else echo "跳过"; fi;
   echo "移除优化配置..."; if [ -f "$OPTIMIZE_CONFIG_FILE" ]; then rm -v "$OPTIMIZE_CONFIG_FILE" && log "$OPTIMIZE_CONFIG_FILE已移除" || log "移除 $OPTIMIZE_CONFIG_FILE 失败"; else echo "跳过"; fi;
   echo "移除优化脚本..."; if [ -f "$SCRIPT_PATH" ]; then rm -v "$SCRIPT_PATH" && log "$SCRIPT_PATH已移除" || log "移除 $SCRIPT_PATH 失败"; else echo "跳过"; fi;
   echo "移除快捷命令..."; find /usr/local/bin/ -type l 2>/dev/null | while read -r link; do target=$(readlink -f "$link" 2>/dev/null); if [[ "$target" == *setup_optimize_server.sh || "$target" == *cristsau_modular_optimizer* ]]; then echo "移除 $link ..."; rm -v "$link" && log "移除 $link"; fi; done; if [ -L "/usr/local/bin/cristsau" ]; then target=$(readlink -f "/usr/local/bin/cristsau" 2>/dev/null); if [[ "$target" == *setup_optimize_server.sh || "$target" == *cristsau_modular_optimizer* ]]; then echo "移除 cristsau ..."; rm -v "/usr/local/bin/cristsau" && log "移除 cristsau"; fi; fi;
   echo "移除主脚本logrotate配置..."; if [ -f "/etc/logrotate.d/setup_optimize_server_main" ]; then rm -v "/etc/logrotate.d/setup_optimize_server_main" && log "移除主logrotate配置"; else echo "跳过"; fi;
   echo "移除优化脚本logrotate配置..."; if [ -f "/etc/logrotate.d/optimize_server" ]; then rm -v "/etc/logrotate.d/optimize_server" && log "移除优化脚本logrotate配置"; else echo "跳过"; fi;

   echo -e "\n\033[33m⚠ 日志保留: $LOG_FILE\033[0m"; read -p "是否删除日志?(y/N): " del_log; if [[ "$del_log" == "y" || "$del_log" == "Y" ]]; then if [ -f "$LOG_FILE" ]; then rm -v "$LOG_FILE" && echo "已删除"; fi; fi;
   echo -e "\033[31m✔ 卸载完成\033[0m"; log "卸载完成";
   echo "提示：可能需要手动清理 Docker 配置 (/etc/docker/daemon.json)。";
   exit 0;
}


update_from_github() {
   log "运行更新程序"
   echo -e "\033[36m▶ 从 GitHub 更新脚本...\033[0m"; local CSD CSN TP GU TF LV CVL force force_dg;
   CSD=$(dirname "$(readlink -f "${BASH_SOURCE[1]:-$0}")"); CSN=$(basename "$(readlink -f "${BASH_SOURCE[1]:-$0}")"); TP="$CSD/$CSN";
   # --- 修改 GITHUB URL 指向子目录 ---
   GU="https://raw.githubusercontent.com/cristsau/server-optimization-scripts/main/modular_optimizer/setup_optimize_server.sh";
   TF="/tmp/${CSN}.tmp"; echo "当前脚本: $TP"; echo "下载地址: $GU"; echo "临时文件: $TF";
   check_command "wget" || return 1;
   echo "下载..."; if ! wget --no-cache -O "$TF" "$GU" >/dev/null 2>&1; then echo "下载失败"; rm -f "$TF"; log "更新失败:下载错误"; return 1; fi;
   if [ ! -s "$TF" ]; then echo "文件为空"; rm -f "$TF"; log "更新失败:下载文件为空"; return 1; fi;
   if ! bash -n "$TF"; then echo "下载的脚本语法错误!"; rm -f "$TF"; log "更新失败:下载脚本语法错误"; return 1; fi;

   LV=$(grep -m 1 -oP '# 版本：\K[0-9.]+' "$TF"); CVL=$(grep -m 1 -oP '# 版本：\K[0-9.]+' "$TP");
   if [ -z "$LV" ]; then echo "无法提取最新版本"; read -p "强制更新?(y/N):" force; if [[ "$force" != "y" && "$force" != "Y" ]]; then rm -f "$TF"; return 1; fi;
   else echo "当前:$CVL 最新:$LV"; if [ "$CVL" = "$LV" ]; then echo "已是最新"; read -p "强制更新?(y/N):" force; if [ "$force" != "y" && "$force" != "Y" ]; then rm -f "$TF"; return 0; fi; elif [[ "$(printf '%s\n' "$CVL" "$LV" | sort -V | head -n1)" == "$LV" ]]; then echo "当前版本($CVL)比最新版($LV)更新?"; read -p "覆盖为 GitHub 版本 ($LV)？(y/N):" force_dg; if [ "$force_dg" != "y" && "$force_dg" != "Y" ]; then rm -f "$TF"; return 0; fi; fi; fi;
   echo "备份..."; cp "$TP" "${TP}.bak" || { echo "备份失败"; rm -f "$TF"; log "更新失败:备份错误"; return 1; };
   echo "覆盖..."; mv "$TF" "$TP" || { echo "覆盖失败"; cp "${TP}.bak" "$TP"; rm -f "$TF"; log "更新失败:覆盖错误"; return 1; };
   chmod +x "$TP" || log "警告:更新后设置权限失败 $TP";
   echo "更新成功: $TP"; echo "正在重新加载脚本..."; log "脚本更新到 $LV";
   # 更新后需要重新 source 库文件，直接 exec 主脚本最简单
   exec bash "$TP";
   exit 0; # Fallback exit
}
