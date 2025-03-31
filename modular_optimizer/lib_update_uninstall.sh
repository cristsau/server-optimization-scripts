#!/bin/bash
# lib_update_uninstall.sh - Update and uninstall functions (v1.3 - Enhanced uninstall)

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
source "$SCRIPT_DIR/lib_utils.sh" # For log, manage_cron, check_command

# --- Functions ---
install_alias() {
   # 原函数保持不变
   log "运行别名安装向导"; echo -e "\033[36m▶ 快捷命令安装向导\033[0m"; local cmd current_script_path target_link script_in_path; read -p "命令名(默认cristsau): " cmd; cmd=${cmd:-cristsau}; if ! [[ "$cmd" =~ ^[a-zA-Z0-9_-]+$ ]]; then echo "非法字符"; return 1; fi; current_script_path=$(readlink -f "${BASH_SOURCE[1]:-$0}"); if [[ ! "$current_script_path" || "$current_script_path" != *setup_optimize_server.sh ]]; then script_in_path=$(which setup_optimize_server.sh 2>/dev/null); if [ -n "$script_in_path" ]; then current_script_path=$(readlink -f "$script_in_path"); elif [ -f "$SCRIPT_DIR/setup_optimize_server.sh" ]; then current_script_path="$SCRIPT_DIR/setup_optimize_server.sh"; else echo "无法确定主脚本路径"; return 1; fi; fi; target_link="/usr/local/bin/$cmd"; log "创建软链接 $target_link -> $current_script_path"; ln -sf "$current_script_path" "$target_link" || { echo "创建失败"; log "创建快捷命令 $cmd 失败"; return 1; }; chmod +x "$current_script_path" || log "警告:设置主脚本权限失败"; echo -e "\033[32m✔ 已创建快捷命令: $cmd -> $current_script_path\033[0m"; log "创建快捷命令 $cmd"; return 0;
}

uninstall() {
   log "运行卸载程序"; echo -e "\033[31m▶ 开始卸载...\033[0m"; 
   local confirm target link del_log;
   read -p "确定完全卸载?(y/N): " confirm; 
   if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo "取消"; return; fi; 
   log "开始卸载";

   # 移除优化任务 cron
   echo "移除优化任务..."; 
   manage_cron || log "移除优化cron失败";

   # 移除备份任务和配置
   echo "移除备份任务..."; 
   if [ -f "$BACKUP_CRON" ]; then rm -v "$BACKUP_CRON" && log "$BACKUP_CRON已移除" || log "移除 $BACKUP_CRON 失败"; else echo "跳过"; fi;
   echo "移除备份配置..."; 
   if [ -f "$CONFIG_FILE" ]; then rm -v "$CONFIG_FILE" && log "$CONFIG_FILE已移除" || log "移除 $CONFIG_FILE 失败"; else echo "跳过"; fi;

   # 移除优化配置和脚本
   echo "移除优化配置..."; 
   if [ -f "$OPTIMIZE_CONFIG_FILE" ]; then rm -v "$OPTIMIZE_CONFIG_FILE" && log "$OPTIMIZE_CONFIG_FILE已移除" || log "移除 $OPTIMIZE_CONFIG_FILE 失败"; else echo "跳过"; fi;
   echo "移除优化脚本..."; 
   if [ -f "$SCRIPT_PATH" ]; then rm -v "$SCRIPT_PATH" && log "$SCRIPT_PATH已移除" || log "移除 $SCRIPT_PATH 失败"; else echo "跳过"; fi;

   # 移除快捷命令
   echo "移除快捷命令..."; 
   find /usr/local/bin/ -type l 2>/dev/null | while read -r link; do 
      target=$(readlink -f "$link" 2>/dev/null); 
      if [[ "$target" == *setup_optimize_server.sh || "$target" == *cristsau_modular_optimizer* ]]; then 
         echo "移除 $link ..."; rm -v "$link" && log "移除 $link"; 
      fi; 
   done;
   if [ -L "/usr/local/bin/cristsau" ]; then 
      target=$(readlink -f "/usr/local/bin/cristsau" 2>/dev/null); 
      if [[ "$target" == *setup_optimize_server.sh || "$target" == *cristsau_modular_optimizer* ]]; then 
         echo "移除 cristsau ..."; rm -v "/usr/local/bin/cristsau" && log "移除 cristsau"; 
      fi; 
   fi;

   # 移除 logrotate 配置
   echo "移除主脚本logrotate配置..."; 
   if [ -f "/etc/logrotate.d/setup_optimize_server_main" ]; then rm -v "/etc/logrotate.d/setup_optimize_server_main" && log "移除主logrotate配置"; else echo "跳过"; fi;
   echo "移除优化脚本logrotate配置..."; 
   if [ -f "/etc/logrotate.d/optimize_server" ]; then rm -v "/etc/logrotate.d/optimize_server" && log "移除优化脚本logrotate配置"; else echo "跳过"; fi;

   # 移除流量监控相关内容
   echo "移除流量监控脚本..."; 
   if [ -f "/usr/local/bin/traffic_monitor.sh" ]; then rm -v "/usr/local/bin/traffic_monitor.sh" && log "移除流量监控脚本"; else echo "跳过"; fi;
   echo "移除流量监控日志..."; 
   if [ -f "/root/log/traffic_monitor.log" ]; then rm -v "/root/log/traffic_monitor.log" && log "移除流量监控日志"; else echo "跳过"; fi;
   echo "移除流量监控临时文件..."; 
   rm -fv /tmp/daily_report_sent /tmp/vnstat_80_percent /tmp/vnstat_90_percent /tmp/vnstat_reset && log "移除流量监控临时文件";
   echo "移除流量监控 cron 任务..."; 
   crontab -l 2>/dev/null | grep -v "/usr/local/bin/traffic_monitor.sh" > /tmp/crontab_cleaned; 
   crontab /tmp/crontab_cleaned && log "移除流量监控 cron 任务" || log "移除流量监控 cron 失败"; 
   rm -f /tmp/crontab_cleaned;

   # 恢复防火墙规则（如果流量监控修改过）
   echo "检查并恢复防火墙规则..."; 
   if ! iptables -L INPUT | grep -q "policy ACCEPT"; then
      iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT; 
      iptables -F; iptables -t nat -F; iptables -t mangle -F;
      log "恢复 IPv4 防火墙规则"; echo "已恢复 IPv4 防火墙规则";
   else
      echo "IPv4 防火墙无需恢复";
   fi
   if command -v ip6tables >/dev/null && ! ip6tables -L INPUT | grep -q "policy ACCEPT"; then
      ip6tables -P INPUT ACCEPT; ip6tables -P FORWARD ACCEPT; ip6tables -P OUTPUT ACCEPT; 
      ip6tables -F; ip6tables -t mangle -F;
      log "恢复 IPv6 防火墙规则"; echo "已恢复 IPv6 防火墙规则";
   else
      echo "IPv6 防火墙无需恢复或未安装 ip6tables";
   fi;

   # 可选移除工具箱安装的组件
   echo "检查工具箱安装的组件..."; 
   if command -v docker >/dev/null; then
      read -p "检测到 Docker，是否卸载？(y/N): " docker_uninstall;
      if [[ "$docker_uninstall" == "y" || "$docker_uninstall" == "Y" ]]; then
         apt-get remove --purge -y docker.io docker-ce docker-ce-cli containerd.io;
         rm -rf /var/lib/docker;
         log "卸载 Docker"; echo "已卸载 Docker";
      fi
   fi
   if dpkg -s systemd-timesyncd >/dev/null 2>&1; then
      read -p "检测到 systemd-timesyncd，是否禁用并移除？(y/N): " timesync_uninstall;
      if [[ "$timesync_uninstall" == "y" || "$timesync_uninstall" == "Y" ]]; then
         systemctl disable systemd-timesyncd; apt-get remove --purge -y systemd-timesyncd;
         log "移除 systemd-timesyncd"; echo "已移除 systemd-timesyncd";
      fi
   fi
   if grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf; then
      read -p "检测到 BBR 配置，是否恢复默认 sysctl 设置？(y/N): " bbr_reset;
      if [[ "$bbr_reset" == "y" || "$bbr_reset" == "Y" ]]; then
         sed -i '/# Added by optimize_server script/,/tcp_congestion_control=bbr/d' /etc/sysctl.conf;
         sysctl -p && log "恢复 sysctl 配置" || log "恢复 sysctl 失败";
         echo "已尝试恢复 sysctl 配置";
      fi
   fi

   # 移除主脚本和模块文件
   echo "移除主脚本和模块文件..."; 
   local main_script=$(readlink -f "${BASH_SOURCE[1]:-$0}");
   if [ -f "$main_script" ]; then 
      rm -v "$main_script" && log "移除主脚本 $main_script" || log "移除主脚本失败"; 
   fi;
   for lib in "$SCRIPT_DIR"/lib_*.sh; do 
      if [ -f "$lib" ]; then rm -v "$lib" && log "移除模块 $lib" || log "移除模块 $lib 失败"; 
      fi; 
   done;

   # 删除日志和临时日志
   echo -e "\n\033[33m⚠ 日志保留: $LOG_FILE 和 $TEMP_LOG\033[0m"; 
   read -p "是否删除所有日志文件?(y/N): " del_log; 
   if [[ "$del_log" == "y" || "$del_log" == "Y" ]]; then 
      [ -f "$LOG_FILE" ] && rm -v "$LOG_FILE" && echo "已删除 $LOG_FILE"; 
      [ -f "$TEMP_LOG" ] && rm -v "$TEMP_LOG" && echo "已删除 $TEMP_LOG"; 
   fi;

   echo -e "\033[31m✔ 卸载完成\033[0m"; 
   log "卸载完成"; 
   echo "提示：如需清理 vnstat 或其他手动安装的依赖，请使用包管理器"; 
   exit 0;
}

update_from_github() {
   # 原函数保持不变
   log "运行更新程序"; echo -e "\033[36m▶ 从 GitHub 更新脚本...\033[0m"; local CSD CSN TP GU TF LV CVL force force_dg; CSD=$(dirname "$(readlink -f "${BASH_SOURCE[1]:-$0}")"); CSN=$(basename "$(readlink -f "${BASH_SOURCE[1]:-$0}")"); TP="$CSD/$CSN"; GU="https://raw.githubusercontent.com/cristsau/server-optimization-scripts/main/modular_optimizer/setup_optimize_server.sh"; TF="/tmp/${CSN}.tmp"; echo "当前:$TP"; echo "下载:$GU"; echo "临时:$TF"; check_command "wget" || return 1; echo "下载..."; if ! wget --no-cache -O "$TF" "$GU" >/dev/null 2>&1; then echo "下载失败"; rm -f "$TF"; log "更新失败:下载错误"; return 1; fi; if [ ! -s "$TF" ]; then echo "文件为空"; rm -f "$TF"; log "更新失败:下载文件为空"; return 1; fi; if ! bash -n "$TF"; then echo "下载脚本语法错误!"; rm -f "$TF"; log "更新失败:下载脚本语法错误"; return 1; fi; LV=$(grep -m 1 -oP '# 版本：\K[0-9.]+' "$TF"); CVL=$(grep -m 1 -oP '# 版本：\K[0-9.]+' "$TP"); if [ -z "$LV" ]; then echo "无法提取最新版本"; read -p "强制更新?(y/N):" force; if [[ "$force" != "y" && "$force" != "Y" ]]; then rm -f "$TF"; return 1; fi; else echo "当前:$CVL 最新:$LV"; if [ "$CVL" = "$LV" ]; then echo "已是最新"; read -p "强制更新?(y/N):" force; if [ "$force" != "y" && "$force" != "Y" ]]; then rm -f "$TF"; return 0; fi; elif [[ "$(printf '%s\n' "$CVL" "$LV" | sort -V | head -n1)" == "$LV" ]]; then echo "当前版本($CVL)比最新版($LV)更新?"; read -p "覆盖为 GitHub 版本 ($LV)？(y/N):" force_dg; if [ "$force_dg" != "y" && "$force_dg" != "Y" ]]; then rm -f "$TF"; return 0; fi; fi; fi; echo "备份..."; cp "$TP" "${TP}.bak" || { echo "备份失败"; rm -f "$TF"; log "更新失败:备份错误"; return 1; }; echo "覆盖..."; mv "$TF" "$TP" || { echo "覆盖失败"; cp "${TP}.bak" "$TP"; rm -f "$TF"; log "更新失败:覆盖错误"; return 1; }; chmod +x "$TP" || log "警告:更新后设置权限失败 $TP"; echo "更新成功: $TP"; echo "正在重新加载脚本..."; log "脚本更新到 $LV"; exec bash "$TP"; exit 0;
}