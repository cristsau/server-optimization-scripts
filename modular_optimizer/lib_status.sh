#!/bin/bash
# lib_status.sh - Status display functions (v7.2 - Enhanced Cron Display & UI)

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
# Assume needed global vars LOG_FILE, CONFIG_FILE, BACKUP_CRON, SCRIPT_PATH, CURRENT_VERSION, SCRIPT_DIR are accessible
# shellcheck source=./lib_utils.sh
source "$SCRIPT_DIR/lib_utils.sh" # For log, clear_cmd, convert_weekday, get_next_cron_time

# --- Functions ---
get_server_status() {
   # Define status vars globally or ensure view_status can access them
   CPU_MODEL=$(lscpu | grep "Model name:" | sed 's/Model name:[[:space:]]*//')
   CPU_CORES=$(nproc)
   CPU_FREQ=$(lscpu | grep "CPU MHz:" | sed 's/CPU MHz:[[:space:]]*//' | awk '{printf "%.0f", $1}'); [ -z "$CPU_FREQ" ] && CPU_FREQ=$(grep 'cpu MHz' /proc/cpuinfo | head -n1 | sed 's/cpu MHz[[:space:]]*:[[:space:]]*//' | awk '{printf "%.0f", $1}'); [ -z "$CPU_FREQ" ] && CPU_FREQ="未知";
   MEM_INFO=$(free -m | grep Mem); MEM_USED=$(echo "$MEM_INFO" | awk '{print $3}'); MEM_TOTAL=$(echo "$MEM_INFO" | awk '{print $2}'); MEM_USAGE="${MEM_USED} MiB / ${MEM_TOTAL} MiB";
   SWAP_INFO=$(free -m | grep Swap); SWAP_USED=$(echo "$SWAP_INFO" | awk '{print $3}'); SWAP_TOTAL=$(echo "$SWAP_INFO" | awk '{print $2}'); if [ "$SWAP_TOTAL" -gt 0 ]; then SWAP_USAGE="${SWAP_USED} MiB / ${SWAP_TOTAL} MiB"; else SWAP_USAGE="未启用"; fi;
   DISK_INFO=$(df -h / | grep '/'); DISK_USED=$(echo "$DISK_INFO" | awk '{print $3}'); DISK_TOTAL=$(echo "$DISK_INFO" | awk '{print $2}'); DISK_USAGE="${DISK_USED} / ${DISK_TOTAL}";
   UPTIME=$(uptime -p | sed 's/up //');
   OS_VERSION=$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo "未知操作系统")

   DISK_PERCENT=$(df / | grep '/' | awk '{ print $5 }' | sed 's/%//') || DISK_PERCENT=""
   MEM_INFO_RAW=$(free | grep Mem); MEM_TOTAL_RAW=$(echo "$MEM_INFO_RAW" | awk '{print $2}'); MEM_USED_RAW=$(echo "$MEM_INFO_RAW" | awk '{print $3}'); MEM_FREE_RAW=$(echo "$MEM_INFO_RAW" | awk '{print $4}'); MEM_BUFFCACHE_RAW=$(echo "$MEM_INFO_RAW" | awk '{print $6}');
   if [[ -n "$MEM_TOTAL_RAW" && "$MEM_TOTAL_RAW" -ne 0 ]]; then MEM_AVAILABLE_RAW=$((MEM_FREE_RAW + MEM_BUFFCACHE_RAW)); MEM_USED_PERCENT=$(( 100 * (MEM_TOTAL_RAW - MEM_AVAILABLE_RAW) / MEM_TOTAL_RAW )); else MEM_USED_PERCENT=0; fi
   SWAP_INFO_RAW=$(free | grep Swap); SWAP_TOTAL_RAW=$(echo "$SWAP_INFO_RAW" | awk '{print $2}'); SWAP_USED_RAW=$(echo "$SWAP_INFO_RAW" | awk '{print $3}');
   if [[ -n "$SWAP_TOTAL_RAW" && "$SWAP_TOTAL_RAW" -ne 0 ]]; then SWAP_USED_PERCENT=$(( 100 * SWAP_USED_RAW / SWAP_TOTAL_RAW )); else SWAP_USED_PERCENT=0; fi

   export DISK_PERCENT MEM_USED_PERCENT SWAP_USAGE SWAP_USED_PERCENT SWAP_TOTAL_RAW
}

# Helper function to format cron schedule (Basic)
format_cron_schedule_basic() {
    local min="$1" hour="$2" dom="$3" mon="$4" dow="$5" schedule_str=""
    # Handle * first
    if [[ "$min$hour$dom$mon$dow" == "*****" ]]; then echo "每分钟"; return; fi
    # Specific time daily
    if [[ "$min" =~ ^[0-9]+$ && "$hour" =~ ^[0-9]+$ && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then printf "每天 %02d:%02d" "$hour" "$min"; return; fi
    # Specific time weekly
    if [[ "$min" =~ ^[0-9]+$ && "$hour" =~ ^[0-9]+$ && "$dom" == "*" && "$mon" == "*" && "$dow" =~ ^[0-6]$ ]]; then printf "每周%s %02d:%02d" "$(convert_weekday "$dow")" "$hour" "$min"; return; fi
    # Specific time monthly
    if [[ "$min" =~ ^[0-9]+$ && "$hour" =~ ^[0-9]+$ && "$dom" =~ ^[0-9]+$ && "$mon" == "*" && "$dow" == "*" ]]; then printf "每月%s日 %02d:%02d" "$dom" "$hour" "$min"; return; fi
    # Hourly specific minute
    if [[ "$min" =~ ^[0-9]+$ && "$hour" == "*" && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then printf "每小时 %02d分" "$min"; return; fi
    # Every N minutes
    if [[ "$min" == "*/"* && "$hour" == "*" && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then printf "每%s分钟" "${min#\*/}"; return; fi
    # Fallback: show raw schedule
    printf "%s %s %s %s %s" "$min" "$hour" "$dom" "$mon" "$dow"
}


view_status() {
   clear_cmd; echo -e "\033[34m 📊 任务状态信息 ▍\033[0m";
   echo -e "\n\033[36mℹ️  脚本信息 ▍\033[0m";
   printf "%-16s: %s\n" "当前版本" "$CURRENT_VERSION"; printf "%-16s: %s\n" "优化脚本" "$SCRIPT_PATH"; printf "%-16s: %s\n" "日志文件" "$LOG_FILE"; local log_size; log_size=$(du -sh "$LOG_FILE" 2>/dev/null || echo '未知'); printf "%-16s: %s\n" "日志大小" "$log_size"; if [ -f "$SCRIPT_PATH" ]; then printf "%-16s: ✅ 已安装\n" "安装状态"; local itime; itime=$(stat -c %Y "$SCRIPT_PATH" 2>/dev/null); if [ -n "$itime" ]; then printf "%-16s: %s\n" "安装时间" "$(date -d "@$itime" '+%Y-%m-%d %H:%M:%S')"; fi; else printf "%-16s: ❌ 未安装\n" "安装状态"; fi;

   echo -e "\n\033[36m🖥️  服务器状态 ▍\033[0m"; get_server_status;
   printf "%-14s : %s\n" "CPU 型号" "$CPU_MODEL"; printf "%-14s : %s\n" "CPU 核心数" "$CPU_CORES"; printf "%-14s : %s MHz\n" "CPU 频率" "$CPU_FREQ"; printf "%-14s : %s (%s%% 已用)\n" "内存" "$MEM_USAGE" "${MEM_USED_PERCENT:-?}"; printf "%-14s : %s (%s%% 已用)\n" "Swap" "$SWAP_USAGE" "${SWAP_USED_PERCENT:-?}"; printf "%-14s : %s (%s%% 已用)\n" "硬盘空间(/)" "$DISK_USAGE" "${DISK_PERCENT:-?}"; printf "%-14s : %s\n" "系统在线时间" "$UPTIME"; printf "%-14s : %s\n" "系统" "$OS_VERSION";

   echo -e "\n\033[36m💾 DB客户端 ▍\033[0m"; echo -n "MySQL: "; if command -v mysqldump >/dev/null; then echo "✅ 已安装 ($(which mysqldump))"; else echo "❌ 未安装"; fi; echo -n "PostgreSQL: "; if command -v psql >/dev/null && command -v pg_dump >/dev/null; then echo "✅ 已安装 ($(which psql))"; else echo "❌ 未安装"; fi;

   # --- Unified Cron Task Display (Categorized) ---
   echo -e "\n\033[36m🗓️  所有计划任务 ▍\033[0m";
   local script_tasks=() system_tasks=() line user command schedule source cron_output f task_entry schedule_str m h dom mon dow task_count=0

   # Process User Crontab
   source="User Cron (root)"; #log "读取用户 Crontab..." # Removed log
   cron_output=$(crontab -l 2>/dev/null)
   if [ -n "$cron_output" ]; then
        while IFS= read -r line; do
            if [[ -n "$line" && ! "$line" =~ ^\s*# ]]; then
                if [[ "$line" =~ ^[0-9\*\/\,-]+ && $(echo "$line" | wc -w) -ge 6 ]]; then
                    task_count=$((task_count + 1))
                    read -r m h dom mon dow command <<< "$line"
                    schedule_str=$(format_cron_schedule_basic "$m" "$h" "$dom" "$mon" "$dow")
                    task_entry=$(printf "  %-28s [%s]\n      └─ %s" "$schedule_str" "$source" "$command")
                    if [[ "$command" == "$SCRIPT_PATH" ]]; then script_tasks+=("$task_entry"); else system_tasks+=("$task_entry"); fi
                fi
            fi
        done <<< "$cron_output"
   fi # Removed log

   # Process /etc/crontab
   source="/etc/crontab"; if [ -f "$source" ]; then #log "读取 $source ..." # Removed log
        while IFS= read -r line; do
             if [[ -n "$line" && ! "$line" =~ ^\s*# ]]; then
                 if [[ "$line" =~ ^[0-9\*\/\,-]+ && $(echo "$line" | wc -w) -ge 7 ]]; then
                      task_count=$((task_count + 1))
                      read -r m h dom mon dow user command <<< "$line";
                      schedule_str=$(format_cron_schedule_basic "$m" "$h" "$dom" "$mon" "$dow")
                      task_entry=$(printf "  %-28s [%s]\n      └─ User: %s | Cmd: %s" "$schedule_str" "$source" "$user" "$command")
                      system_tasks+=("$task_entry");
                 fi
             fi
        done < "$source"; # Removed log
   fi

   # Process /etc/cron.d/*
   if [ -d "/etc/cron.d" ]; then #log "读取 /etc/cron.d/ 目录..." # Removed log
       local f source_file source_short # Declare loop variables locally
       for f in /etc/cron.d/*; do
           if [ -f "$f" ] && [[ ! "$f" =~ (\.bak|\.old|\.disabled|~) ]] && [[ "$f" != *.* ]] ; then
               source_file=$(basename "$f"); source_short="/etc/cron.d/$source_file"; #log "处理 $source_file ..." # Removed log
               while IFS= read -r line; do
                   if [[ -n "$line" && ! "$line" =~ ^\s*# ]]; then
                       if [[ "$line" =~ ^[0-9\*\/\,-]+ && $(echo "$line" | wc -w) -ge 7 ]]; then
                            task_count=$((task_count + 1))
                            read -r m h dom mon dow user command <<< "$line";
                            schedule_str=$(format_cron_schedule_basic "$m" "$h" "$dom" "$mon" "$dow")
                            task_entry=$(printf "  %-28s [%s]\n      └─ User: %s | Cmd: %s" "$schedule_str" "$source_short" "$user" "$command")
                            if [[ "$f" == "$BACKUP_CRON" ]]; then script_tasks+=("$task_entry");
                            else system_tasks+=("$task_entry"); fi
                       fi
                   fi
               done < "$f"; # Removed log
            # Removed log for skipped files
           fi
       done
   fi

   # Print categorized tasks with new headers
   printf "\n  \033[1;35m▌ 脚本配置计划任务 ▍\033[0m\n" # Pink sub-header
   if [ ${#script_tasks[@]} -gt 0 ]; then printf "%s\n\n" "${script_tasks[@]}";
   else echo "    (无)"; fi

   printf "\n  \033[1;35m▌ 其他系统计划任务 ▍\033[0m\n" # Pink sub-header
   if [ ${#system_tasks[@]} -gt 0 ]; then printf "%s\n\n" "${system_tasks[@]}";
   else echo "    (无)"; fi

   if [ $task_count -eq 0 ]; then # Check if any task was found at all
       log "未在任何位置找到有效计划任务"
   fi
   # --- End Unified Cron Task Display ---


   echo -e "\n\033[36m🚀 下一次自动优化详情 ▍\033[0m"; cron_job=$(crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH"); if [ -n "$cron_job" ]; then cmin=$(echo "$cron_job"|awk '{print $1}'); chr=$(echo "$cron_job"|awk '{print $2}'); cday=$(echo "$cron_job"|awk '{print $5}'); ntime=$(get_next_cron_time "$cmin" "$chr" "$cday"); printf "  %-14s: %s (%s %02d:%02d)\n" "下次执行时间" "$ntime" "$(convert_weekday "$cday")" "$chr" "$cmin"; echo "  计划执行任务:"; echo "    ▫️ 检查依赖"; echo "    ▫️ 配置日志轮转 (脚本 & 系统)"; echo "    ▫️ 清理旧系统日志 (根据配置)"; echo "    ▫️ 配置/清理 Docker 日志 (根据配置)"; echo "    ▫️ 清理 APT 缓存"; echo "    ▫️ 清理旧内核 (根据配置)"; echo "    ▫️ 清理 /tmp 目录 (根据配置)"; echo "    ▫️ 清理用户缓存 (根据配置)"; else echo -e "  \033[33m⚠️  未设置优化计划任务。\033[0m"; fi

   echo -e "\n\033[36m🕒 上一次任务执行详情 (仅限本工具任务) ▍\033[0m"; if [ -f "$LOG_FILE" ]; then
      local start_ln end_ln; start_ln=$(grep -n '=== 优化任务开始' "$LOG_FILE" | tail -n 1 | cut -d: -f1); end_ln=$(grep -n '=== 优化任务结束 ===' "$LOG_FILE" | tail -n 1 | cut -d: -f1);
      if [[ -n "$start_ln" && -n "$end_ln" && "$start_ln" -le "$end_ln" ]]; then
          local run_log stime etime ssec esec task_info summary unique_tasks=(); run_log=$(sed -n "${start_ln},${end_ln}p" "$LOG_FILE"); stime=$(echo "$run_log"|head -n 1|awk '{print $1" "$2}'); etime=$(echo "$run_log"|tail -n 1|awk '{print $1" "$2}'); printf "  %-10s: %s\n" "开始时间" "$stime"; printf "  %-10s: %s\n" "结束时间" "$etime"; ssec=$(date -d "$stime" +%s 2>/dev/null); esec=$(date -d "$etime" +%s 2>/dev/null); if [[ -n "$ssec" && -n "$esec" && "$esec" -ge "$ssec" ]]; then printf "  %-10s: %s 秒\n" "执行时长" "$((esec-ssec))"; else printf "  %-10s: 无法计算\n" "执行时长"; fi;
          echo "  任务摘要 (基于日志):";
          while IFS= read -r line; do task_info=$(echo "$line" | sed 's/^[0-9-]* [0-9:]* - //'); summary="";
              case "$task_info" in "检查优化脚本依赖..."|"依赖检查通过." ) ;; "配置脚本日志轮转..."|"脚本日志轮转配置完成." ) summary="✅ 配置脚本日志轮转";; "配置系统日志轮转..."|"系统日志轮转配置完成." ) summary="✅ 配置系统日志轮转";; "清理超过"*|"旧系统日志清理完成." ) summary="✅ 清理旧系统日志";; "配置Docker日志轮转..."|"Docker日志配置完成"* ) summary="✅ 配置Docker日志轮转";; "清理Docker容器日志..."|"Docker容器日志清理完成." ) summary="✅ 清理Docker容器日志";; "清理APT缓存..."|"APT缓存清理完成." ) summary="✅ 清理APT缓存";; "清理旧内核..."|"旧内核清理任务结束."|"无旧内核可清理" ) summary="✅ 清理旧内核";; "清理/tmp目录..."|"临时文件清理完成." ) summary="✅ 清理/tmp目录";; "清理用户缓存..."|"用户缓存清理完成." ) summary="✅ 清理用户缓存";; *"错误"*|*"失败"*|*"警告"*) summary="\033[31m❌ ${task_info}\033[0m";; esac;
              if [[ -n "$summary" && ! " ${unique_tasks[*]} " =~ " $summary " ]]; then unique_tasks+=("$summary"); fi
          done <<< "$(echo "$run_log" | grep -v "===" | grep -v "当前磁盘使用情况")"
          if [ ${#unique_tasks[@]} -gt 0 ]; then for task_summary in "${unique_tasks[@]}"; do echo -e "    $task_summary"; done; else echo "    (未解析到明确的任务摘要)"; fi
      else echo "  ⚠️  未找到完整的上一次优化任务记录"; fi
   else echo "  ⚠️  日志文件不存在"; fi

   echo -e "\n\033[36m💡 优化建议 ▍\033[0m"; local suggestions_found=0;
   if [[ -z "${DISK_PERCENT:-}" || -z "${MEM_USED_PERCENT:-}" || -z "${SWAP_USED_PERCENT:-}" ]]; then get_server_status; fi
   if [[ -n "$DISK_PERCENT" && "$DISK_PERCENT" -gt 85 ]]; then echo -e "  ⚠️  磁盘(/) > 85% ($DISK_PERCENT%), 建议清理或扩容。"; suggestions_found=1; fi
   if [[ -n "$MEM_USED_PERCENT" && "$MEM_USED_PERCENT" -gt 90 ]]; then echo -e "  ⚠️  内存 > 90% ($MEM_USED_PERCENT%), 建议检查进程。"; suggestions_found=1; fi
   if [[ "${SWAP_USAGE}" != "未启用" && -n "$SWAP_USED_PERCENT" && "$SWAP_USED_PERCENT" -gt 30 ]]; then echo -e "  ⚠️  Swap > 30% ($SWAP_USED_PERCENT%), 可能内存不足。"; suggestions_found=1; fi
   if [ ! -f "$SCRIPT_PATH" ]; then echo -e "  ℹ️  优化脚本未安装, 运行选项 1。"; suggestions_found=1; elif ! crontab -l 2>/dev/null | grep -Fq "$SCRIPT_PATH"; then echo -e "  ℹ️  优化脚本未计划, 运行选项 1。"; suggestions_found=1; fi
   if [ ! -f "$CONFIG_FILE" ] || [ ! -f "$BACKUP_CRON" ] || ! grep -qE '[^[:space:]]' "$BACKUP_CRON" 2>/dev/null ; then echo -e "  ℹ️  备份未配置/计划, 运行选项 6 -> 4。"; suggestions_found=1; fi
   if [ -f "$LOG_FILE" ]; then recent_errors=$(grep -E "$(date +%Y-%m-%d).*(ERROR|FAIL|错误|失败)" "$LOG_FILE" | tail -n 3); if [ -n "$recent_errors" ]; then echo -e "  ❌  日志中发现近期错误, 请检查 $LOG_FILE"; suggestions_found=1; fi; fi
   if [ $suggestions_found -eq 0 ]; then echo -e "  ✅  暂无明显问题建议。"; fi

   echo -e "\033[34m▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀\033[0m";
}
