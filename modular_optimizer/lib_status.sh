#!/bin/bash
# lib_status.sh - Status display functions (v1.3 - Fixed traffic warning)

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
# Assume global vars: CURRENT_VERSION, SCRIPT_PATH, LOG_FILE, BACKUP_CRON, OPTIMIZE_CONFIG_FILE, SCRIPT_DIR are accessible
source "$SCRIPT_DIR/lib_utils.sh" # For log, clear_cmd, check_command

# --- Helper Functions ---

# Convert cron schedule to human-readable format
format_cron_schedule_human() {
   local m="$1" h="$2" dom="$3" mon="$4" dow="$5" schedule=""
   # Minute
   [ "$m" = "*" ] && m_str="每分钟" || m_str="${m}分"
   # Hour
   if [ "$h" = "*" ]; then h_str="每小时"
   elif [[ "$h" =~ ^\*/([0-9]+)$ ]]; then h_str="每${BASH_REMATCH[1]}小时"
   else h_str="${h}时"
   fi
   # Day of Month
   [ "$dom" = "*" ] && dom_str="每天" || dom_str="${dom}日"
   # Month
   [ "$mon" = "*" ] && mon_str="每月" || mon_str="${mon}月"
   # Day of Week
   if [ "$dow" = "*" ]; then dow_str=""
   elif [[ "$dow" =~ ^[0-6]$ ]]; then 
      dow_map=(周日 周一 周二 周三 周四 周五 周六); dow_str="每周${dow_map[$dow]}"
   else dow_str="每周?" # Complex dow not fully parsed
   fi

   # Combine schedule parts logically
   if [ "$m" = "*" ] && [ "$h" = "*" ] && [ "$dom" = "*" ] && [ "$mon" = "*" ] && [ "$dow" = "*" ]; then
      schedule="每分钟"
   elif [ "$m" != "*" ] && [ "$h" = "*" ] && [ "$dom" = "*" ] && [ "$mon" = "*" ] && [ "$dow" = "*" ]; then
      schedule="每小时 $m_str"
   elif [ "$h" != "*" ] && [ "$dom" = "*" ] && [ "$mon" = "*" ] && [ "$dow" = "*" ]; then
      schedule="$h_str $m_str"
   elif [ "$dom" != "*" ] && [ "$mon" = "*" ] && [ "$dow" = "*" ]; then
      schedule="$dom_str $h_str $m_str"
   elif [ "$mon" != "*" ] && [ "$dow" = "*" ]; then
      schedule="$mon_str$dom_str $h_str $m_str"
   elif [ "$dow" != "*" ]; then
      schedule="$dow_str $h_str $m_str"
   else
      schedule="$mon_str$dom_str $h_str $m_str"
   fi
   echo "$schedule"
}

# Gather server status information
get_server_status() {
   CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -n 1 | cut -d: -f2- | sed 's/^\s*//;s/\s\+/ /g' || echo "Unknown")
   CPU_CORES=$(nproc 2>/dev/null || echo "Unknown")
   CPU_FREQ=$(grep "cpu MHz" /proc/cpuinfo | head -n 1 | cut -d: -f2 | sed 's/^\s*//' || echo "Unknown")
   if [ -f /proc/meminfo ]; then
      MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
      MEM_FREE=$(awk '/MemFree/ {print $2}' /proc/meminfo)
      MEM_AVAILABLE=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
      MEM_USED=$((MEM_TOTAL - MEM_AVAILABLE))
      MEM_TOTAL_MB=$((MEM_TOTAL / 1024))
      MEM_USED_MB=$((MEM_USED / 1024))
      MEM_USED_PERCENT=$(echo "scale=0; $MEM_USED * 100 / $MEM_TOTAL" | bc 2>/dev/null)
      MEM_USAGE="${MEM_USED_MB} MiB / ${MEM_TOTAL_MB} MiB"
      SWAP_TOTAL=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
      SWAP_FREE=$(awk '/SwapFree/ {print $2}' /proc/meminfo)
      if [ "$SWAP_TOTAL" -gt 0 ]; then
         SWAP_USED=$((SWAP_TOTAL - SWAP_FREE))
         SWAP_TOTAL_MB=$((SWAP_TOTAL / 1024))
         SWAP_USED_MB=$((SWAP_USED / 1024))
         SWAP_TOTAL_RAW=$SWAP_TOTAL_MB
         SWAP_USED_PERCENT=$(echo "scale=0; $SWAP_USED * 100 / $SWAP_TOTAL" | bc 2>/dev/null)
         SWAP_USAGE="${SWAP_USED_MB} MiB / ${SWAP_TOTAL_MB} MiB"
      else
         SWAP_USAGE="未启用"
         SWAP_TOTAL_RAW=0
         SWAP_USED_PERCENT=0
      fi
   else
      MEM_USAGE="未知"; SWAP_USAGE="未知"; MEM_USED_PERCENT="?"; SWAP_USED_PERCENT="?"
   fi
   if [ -f /proc/stat ] && [ -f /proc/uptime ]; then
      UPTIME=$(awk '{days=int($1/86400); hours=int(($1%86400)/3600); mins=int(($1%3600)/60); printf("%d weeks, %d hours, %d minutes",days/7,hours,mins)}' /proc/uptime)
   else
      UPTIME="未知"
   fi
   if [ -f /etc/os-release ]; then
      OS_VERSION=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
   else
      OS_VERSION="未知"
   fi
   DISK_USAGE=$(df -h / | awk 'NR==2 {print $3 " / " $2}')
   DISK_PERCENT=$(df / | awk 'NR==2 {print substr($5, 1, length($5)-1)}')
   CRON_STATUS_ICON=$(systemctl is-active cron >/dev/null 2>&1 && echo "✅" || echo "❌")
   if command -v docker >/dev/null; then 
      DOCKER_STATUS_ICON=$(systemctl is-active docker >/dev/null 2>&1 && echo "✅" || echo "❌")
   else 
      DOCKER_STATUS_ICON="⚪"
   fi
   NET_STATUS_ICON=$(ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && echo "✅" || echo "❌")

   # --- Traffic Stats (only if traffic_monitor.sh exists) ---
   if [ -f "/usr/local/bin/traffic_monitor.sh" ] && command -v vnstat >/dev/null; then
      INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)
      if [ -n "$INTERFACE" ]; then
         vnstat -u >/dev/null 2>&1 # 更新 vnstat 数据库
         TRAFFIC_DATA=$(vnstat -i "$INTERFACE" -m --oneline | grep "$(date +%Y-%m)")
         if [ -n "$TRAFFIC_DATA" ]; then
            TRAFFIC_RX=$(echo "$TRAFFIC_DATA" | cut -d ';' -f 9)  # RX
            TRAFFIC_TX=$(echo "$TRAFFIC_DATA" | cut -d ';' -f 10) # TX
            TRAFFIC_TOTAL=$(echo "$TRAFFIC_DATA" | cut -d ';' -f 11) # Total
            # 计算峰值并保留单位
            TRAFFIC_RX_MIB=$(echo "$TRAFFIC_RX" | sed 's/ GiB/*1024/;s/ MiB//;s/ KiB/\/1024/' | bc -l 2>/dev/null || echo "0")
            TRAFFIC_TX_MIB=$(echo "$TRAFFIC_TX" | sed 's/ GiB/*1024/;s/ MiB//;s/ KiB/\/1024/' | bc -l 2>/dev/null || echo "0")
            TRAFFIC_PEAK=$(echo "$TRAFFIC_RX_MIB $TRAFFIC_TX_MIB" | awk '{if ($1 > $2) print $1; else print $2}')
            TRAFFIC_PEAK_UNIT=$(echo "$TRAFFIC_RX" | grep -o "[GMK]iB" || echo "MiB")
            TRAFFIC_PEAK=$(echo "scale=2; $TRAFFIC_PEAK / 1024" | bc 2>/dev/null || echo "0")
            TRAFFIC_INFO="RX: $TRAFFIC_RX | TX: $TRAFFIC_TX | Total: $TRAFFIC_TOTAL | Peak: $TRAFFIC_PEAK $TRAFFIC_PEAK_UNIT"
         else
            TRAFFIC_INFO="No data for current month"
         fi
      else
         TRAFFIC_INFO="Cannot detect network interface"
      fi
   fi

   export CPU_MODEL CPU_CORES CPU_FREQ MEM_USAGE SWAP_USAGE DISK_USAGE UPTIME OS_VERSION \
          DISK_PERCENT MEM_USED_PERCENT SWAP_USED_PERCENT SWAP_TOTAL_RAW \
          CRON_STATUS_ICON DOCKER_STATUS_ICON NET_STATUS_ICON TRAFFIC_INFO
}

# Main status display function
view_status() {
   clear_cmd
   log "查看服务器和脚本状态"
   echo -e "\033[34m 📊 任务状态信息 ▍\033[0m"

   # --- Script Info ---
   echo -e "\n\033[36mℹ️  脚本信息 ▍\033[0m"
   printf "  %-16s: %s\n" "当前版本" "$CURRENT_VERSION"
   printf "  %-16s: %s\n" "优化脚本" "$SCRIPT_PATH"
   printf "  %-16s: %s\n" "日志文件" "$LOG_FILE"
   local log_size; log_size=$(du -sh "$LOG_FILE" 2>/dev/null | awk '{print $1}' || echo '未知')
   printf "  %-16s: %s\n" "日志大小" "$log_size"
   if [ -f "$SCRIPT_PATH" ]; then 
      printf "  %-16s: ✅ 已安装\n" "安装状态"
      local itime; itime=$(stat -c %Y "$SCRIPT_PATH" 2>/dev/null)
      if [ -n "$itime" ]; then 
         printf "  %-16s: %s\n" "安装时间" "$(date -d "@$itime" '+%Y-%m-%d %H:%M:%S')"
      fi
   else 
      printf "  %-16s: ❌ 未安装\n" "安装状态"
   fi

   # --- Server Status ---
   echo -e "\n\033[36m🖥️  服务器状态 ▍\033[0m"
   get_server_status
   printf "  %-14s: %s\n" "CPU 型号" "$CPU_MODEL"
   printf "  %-14s: %s\n" "CPU 核心数" "$CPU_CORES"
   printf "  %-14s: %s MHz\n" "CPU 频率" "$CPU_FREQ"
   printf "  %-14s: %s (%s%% 已用)\n" "内存" "$MEM_USAGE" "${MEM_USED_PERCENT:-?}"
   printf "  %-14s: %s (%s%% 已用)\n" "Swap" "$SWAP_USAGE" "${SWAP_USED_PERCENT:-?}"
   printf "  %-14s: %s (%s%% 已用)\n" "硬盘空间(/)" "$DISK_USAGE" "${DISK_PERCENT:-?}"
   printf "  %-14s: %s\n" "系统在线时间" "$UPTIME"
   printf "  %-14s: %s\n" "系统" "$OS_VERSION"
   printf "  %-14s: %s Cron | %s Docker | %s Network(v4)\n" "服务简报" "${CRON_STATUS_ICON:-❓}" "${DOCKER_STATUS_ICON:-⚪}" "${NET_STATUS_ICON:-❓}"
   if [ -n "${TRAFFIC_INFO:-}" ]; then
      echo -e "\n  \033[1m流量统计 (本月):\033[0m $TRAFFIC_INFO"
   fi

   # --- Unified Cron Task Display ---
   echo -e "\n\033[36m🗓️  所有计划任务 ▍\033[0m"
   local script_tasks=() system_tasks=() line user command schedule source cron_output f task_entry schedule_str m h dom mon dow task_count=0 short_cmd
   source="User Cron (root)"
   cron_output=$(crontab -l 2>/dev/null)
   if [ -n "$cron_output" ]; then
      while IFS= read -r line; do 
         if [[ -n "$line" && ! "$line" =~ ^\s*# ]]; then 
            if [[ "$line" =~ ^[0-9\*\/\,-]+ && $(echo "$line" | wc -w) -ge 6 ]]; then 
               task_count=$((task_count + 1))
               read -r m h dom mon dow command <<< "$line"
               schedule_str=$(format_cron_schedule_human "$m" "$h" "$dom" "$mon" "$dow")
               if [[ "$command" == "$SCRIPT_PATH" ]]; then 
                  short_cmd="服务器优化任务"
                  task_entry=$(printf "  %-28s [%s]\n      └─ %s" "$schedule_str" "$source" "$short_cmd")
                  script_tasks+=("$task_entry")
               elif [[ "$command" == "/usr/local/bin/traffic_monitor.sh" ]]; then 
                  short_cmd="流量监控任务"
                  task_entry=$(printf "  %-28s [%s]\n      └─ %s" "$schedule_str" "$source" "$short_cmd")
                  script_tasks+=("$task_entry")
               else 
                  if [[ "$command" =~ "acme.sh" ]]; then short_cmd="更新 SSL 证书 (ACME)"
                  elif [[ "$command" =~ "certbot" ]]; then short_cmd="更新 SSL 证书 (Certbot)"
                  elif [[ "$command" =~ "e2scrub" ]]; then short_cmd="检查 ext4 文件系统"
                  elif [[ "$command" =~ "ntpsec" ]]; then short_cmd="同步系统时间 (NTP)"
                  elif [[ "$command" =~ "cron.hourly" ]]; then short_cmd="执行 hourly 任务"
                  elif [[ "$command" =~ "cron.daily" ]]; then short_cmd="执行 daily 任务"
                  elif [[ "$command" =~ "cron.weekly" ]]; then short_cmd="执行 weekly 任务"
                  elif [[ "$command" =~ "cron.monthly" ]]; then short_cmd="执行 monthly 任务"
                  else [ ${#command} -gt 60 ] && short_cmd="${command:0:57}..." || short_cmd="$command"
                  fi
                  task_entry=$(printf "  %-28s [%s]\n      └─ %s" "$schedule_str" "$source" "$short_cmd")
                  system_tasks+=("$task_entry")
               fi
            fi
         fi
      done <<< "$cron_output"
   fi

   source="/etc/crontab"
   if [ -f "$source" ]; then 
      while IFS= read -r line; do 
         if [[ -n "$line" && ! "$line" =~ ^\s*# ]]; then 
            if [[ "$line" =~ ^[0-9\*\/\,-]+ && $(echo "$line" | wc -w) -ge 7 ]]; then 
               task_count=$((task_count + 1))
               read -r m h dom mon dow user command <<< "$line"
               schedule_str=$(format_cron_schedule_human "$m" "$h" "$dom" "$mon" "$dow")
               if [[ "$command" == *"/etc/cron.hourly"* ]]; then short_cmd="执行 hourly 任务"
               elif [[ "$command" == *"/etc/cron.daily"* ]]; then short_cmd="执行 daily 任务"
               elif [[ "$command" == *"/etc/cron.weekly"* ]]; then short_cmd="执行 weekly 任务"
               elif [[ "$command" == *"/etc/cron.monthly"* ]]; then short_cmd="执行 monthly 任务"
               else [ ${#command} -gt 50 ] && short_cmd="${command:0:47}..." || short_cmd="$command"
               fi
               task_entry=$(printf "  %-28s [%s]\n      └─ User: %s | Cmd: %s" "$schedule_str" "$source" "$user" "$short_cmd")
               system_tasks+=("$task_entry")
            fi
         fi
      done < "$source"
   fi

   if [ -d "/etc/cron.d" ]; then 
      local f source_file source_short
      for f in /etc/cron.d/*; do
         if [ -f "$f" ] && [[ ! "$f" =~ (\.bak|\.old|\.disabled|~) ]]; then
            source_file=$(basename "$f")
            source_short="/etc/cron.d/$source_file"
            while IFS= read -r line; do 
               if [[ -n "$line" && ! "$line" =~ ^\s*# ]]; then 
                  if [[ "$line" =~ ^[0-9\*\/\,-]+ && $(echo "$line" | wc -w) -ge 7 ]]; then 
                     task_count=$((task_count + 1))
                     read -r m h dom mon dow user command <<< "$line"
                     schedule_str=$(format_cron_schedule_human "$m" "$h" "$dom" "$mon" "$dow")
                     if [[ "$f" == "$BACKUP_CRON" ]]; then 
                        if [[ "$command" == *"pg_dumpall"* ]]; then short_cmd="PostgreSQL 全部数据库备份"
                        elif [[ "$command" == *"mysqldump --all-databases"* ]]; then short_cmd="MySQL 全部数据库备份"
                        elif [[ "$command" == *"pg_dump"* ]]; then 
                           dbn=$(echo "$command" | grep -oP "(pg_dump.* '|pg_dump.* )\\K[^' |]+")
                           [ -n "$dbn" ] && short_cmd="PostgreSQL 备份 '$dbn'" || short_cmd="PostgreSQL 特定DB备份"
                        elif [[ "$command" == *"mysqldump"* ]]; then 
                           dbn=$(echo "$command" | grep -oP "(mysqldump.* '|mysqldump.* )\\K[^' |]+")
                           [ -n "$dbn" ] && short_cmd="MySQL 备份 '$dbn'" || short_cmd="MySQL 特定DB备份"
                        elif [[ "$command" == *"tar -czf /tmp/backup_data"* ]]; then 
                           srcn=$(echo "$command" | grep -oP "backup_data_\\K[^_]+")
                           [ -n "$srcn" ] && short_cmd="程序数据备份 ($srcn)" || short_cmd="程序数据备份 (tar)"
                        else 
                           short_cmd="备份任务 (命令较长)"
                        fi
                        task_entry=$(printf "  %-28s [%s]\n      └─ User: %s | Cmd: %s" "$schedule_str" "$source_short" "$user" "$short_cmd")
                        script_tasks+=("$task_entry")
                     else 
                        if [[ "$command" =~ "certbot" ]]; then short_cmd="更新 SSL 证书 (Certbot)"
                        elif [[ "$command" =~ "e2scrub" ]]; then short_cmd="检查 ext4 文件系统"
                        elif [[ "$command" =~ "ntpsec" ]]; then short_cmd="同步系统时间 (NTP)"
                        else [ ${#command} -gt 60 ] && short_cmd="${command:0:57}..." || short_cmd="$command"
                        fi
                        task_entry=$(printf "  %-28s [%s]\n      └─ User: %s | Cmd: %s" "$schedule_str" "$source_short" "$user" "$short_cmd")
                        system_tasks+=("$task_entry")
                     fi
                  fi
               fi
            done < "$f"
         fi
      done
   fi

   # Print categorized tasks
   printf "\n  \033[1;35m▌ 脚本配置计划任务 ▍\033[0m\n"
   if [ ${#script_tasks[@]} -gt 0 ]; then printf "%s\n\n" "${script_tasks[@]}"; else echo "    (无)"; fi
   printf "\n  \033[1;35m▌ 其他系统计划任务 ▍\033[0m\n"
   if [ ${#system_tasks[@]} -gt 0 ]; then printf "%s\n\n" "${system_tasks[@]}"; else echo "    (无)"; fi
   if [ $task_count -eq 0 ]; then log "未找到有效计划任务"; fi

   # --- Optimization Suggestions ---
   echo -e "\n\033[36m💡 优化建议 ▍\033[0m"
   local suggestions_found=0
   if [[ -z "${DISK_PERCENT:-}" || -z "${MEM_USED_PERCENT:-}" || -z "${SWAP_USED_PERCENT:-}" ]]; then get_server_status; fi
   if [[ -n "$DISK_PERCENT" && "$DISK_PERCENT" -gt 85 ]]; then 
      echo -e "  ⚠️  磁盘(/) > 85% ($DISK_PERCENT%), 建议清理或扩容。"
      suggestions_found=1
   fi
   if [[ -n "$MEM_USED_PERCENT" && "$MEM_USED_PERCENT" -gt 90 ]]; then 
      echo -e "  ⚠️  内存 > 90% ($MEM_USED_PERCENT%), 建议检查进程。"
      suggestions_found=1
   fi
   if [[ "${SWAP_USAGE}" != "未启用" && -n "$SWAP_USED_PERCENT" && "$SWAP_USED_PERCENT" -gt 30 ]]; then 
      echo -e "  ⚠️  Swap > 30% ($SWAP_USED_PERCENT%), 可能内存不足。"
      suggestions_found=1
   fi

   # 添加流量监控建议
   if [ -f "/usr/local/bin/traffic_monitor.sh" ] && command -v vnstat >/dev/null; then
      local LIMIT_GB=200 # 默认值，可从 traffic_monitor.sh 中读取
      if [ -f "/usr/local/bin/traffic_monitor.sh" ]; then
         LIMIT_GB=$(grep "LIMIT_GB=" /usr/local/bin/traffic_monitor.sh | cut -d'=' -f2 | tr -d '"' | head -n 1)
         [ -z "$LIMIT_GB" ] && LIMIT_GB=200 # 如果未找到则使用默认值
      fi
      # 提取 TRAFFIC_TOTAL 的数值部分并转换为 GB
      local TRAFFIC_TOTAL_NUM=$(echo "$TRAFFIC_TOTAL" | grep -oP '^[0-9.]+' || echo "0")
      local TRAFFIC_TOTAL_UNIT=$(echo "$TRAFFIC_TOTAL" | grep -oP '[GMK]iB' || echo "GiB")
      local TRAFFIC_TOTAL_GB
      case "$TRAFFIC_TOTAL_UNIT" in
         "GiB") TRAFFIC_TOTAL_GB=$(echo "scale=2; $TRAFFIC_TOTAL_NUM" | bc) ;;
         "MiB") TRAFFIC_TOTAL_GB=$(echo "scale=2; $TRAFFIC_TOTAL_NUM / 1024" | bc) ;;
         "KiB") TRAFFIC_TOTAL_GB=$(echo "scale=2; $TRAFFIC_TOTAL_NUM / 1048576" | bc) ;;
         *) TRAFFIC_TOTAL_GB="0" ;;
      esac
      local REMAINING_GB=$(echo "scale=2; $LIMIT_GB - $TRAFFIC_TOTAL_GB" | bc 2>/dev/null || echo "0")
      local TRAFFIC_PERCENT=$(echo "scale=2; ($TRAFFIC_TOTAL_GB / $LIMIT_GB) * 100" | bc 2>/dev/null || echo "0")
      echo -e "  ⚠️  流量预警"
      echo -e "      已用流量: ${TRAFFIC_TOTAL_GB} GB / ${LIMIT_GB} GB"
      echo -e "      剩余流量: ${REMAINING_GB} GB (${TRAFFIC_PERCENT}%)"
      suggestions_found=1
   fi

   if [ $suggestions_found -eq 0 ]; then echo -e "  ✅  暂无明显问题建议。"; fi

   echo -e "\033[34m▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀\033[0m"
}