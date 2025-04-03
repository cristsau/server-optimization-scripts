#!/bin/bash
# lib_status.sh - Status display functions (v1.3.1 - Add traffic thresholds and suggestions)

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
source "$SCRIPT_DIR/lib_utils.sh" # For log, clear_cmd, convert_weekday, get_next_cron_time, format_cron_schedule_human
source "$SCRIPT_DIR/lib_traffic_config.sh" # For traffic config and thresholds

# --- Functions ---
get_server_status() {
    CPU_MODEL=$(lscpu | grep "Model name:" | sed 's/Model name:[[:space:]]*//'); CPU_CORES=$(nproc); CPU_FREQ=$(lscpu | grep "CPU MHz:" | sed 's/CPU MHz:[[:space:]]*//' | awk '{printf "%.0f", $1}'); [ -z "$CPU_FREQ" ] && CPU_FREQ=$(grep 'cpu MHz' /proc/cpuinfo | head -n1 | sed 's/cpu MHz[[:space:]]*:[[:space:]]*//' | awk '{printf "%.0f", $1}'); [ -z "$CPU_FREQ" ] && CPU_FREQ="未知"; MEM_INFO=$(free -m | grep Mem); MEM_USED=$(echo "$MEM_INFO" | awk '{print $3}'); MEM_TOTAL=$(echo "$MEM_INFO" | awk '{print $2}'); MEM_USAGE="${MEM_USED} MiB / ${MEM_TOTAL} MiB"; SWAP_INFO=$(free -m | grep Swap); SWAP_USED=$(echo "$SWAP_INFO" | awk '{print $3}'); SWAP_TOTAL=$(echo "$SWAP_INFO" | awk '{print $2}'); if [ "$SWAP_TOTAL" -gt 0 ]; then SWAP_USAGE="${SWAP_USED} MiB / ${SWAP_TOTAL} MiB"; else SWAP_USAGE="未启用"; fi; DISK_INFO=$(df -h / | grep '/'); DISK_USED=$(echo "$DISK_INFO" | awk '{print $3}'); DISK_TOTAL=$(echo "$DISK_INFO" | awk '{print $2}'); DISK_USAGE="${DISK_USED} / ${DISK_TOTAL}"; UPTIME=$(uptime -p | sed 's/up //'); OS_VERSION=$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo "未知操作系统")
    DISK_PERCENT=$(df / | grep '/' | awk '{ print $5 }' | sed 's/%//') || DISK_PERCENT=""; MEM_INFO_RAW=$(free | grep Mem); MEM_TOTAL_RAW=$(echo "$MEM_INFO_RAW" | awk '{print $2}'); MEM_USED_RAW=$(echo "$MEM_INFO_RAW" | awk '{print $3}'); MEM_FREE_RAW=$(echo "$MEM_INFO_RAW" | awk '{print $4}'); MEM_BUFFCACHE_RAW=$(echo "$MEM_INFO_RAW" | awk '{print $6}'); if [[ -n "$MEM_TOTAL_RAW" && "$MEM_TOTAL_RAW" -ne 0 ]]; then MEM_AVAILABLE_RAW=$((MEM_FREE_RAW + MEM_BUFFCACHE_RAW)); MEM_USED_PERCENT=$(( 100 * (MEM_TOTAL_RAW - MEM_AVAILABLE_RAW) / MEM_TOTAL_RAW )); else MEM_USED_PERCENT=0; fi
    SWAP_INFO_RAW=$(free | grep Swap); SWAP_TOTAL_RAW=$(echo "$SWAP_INFO_RAW" | awk '{print $2}'); SWAP_USED_RAW=$(echo "$SWAP_INFO_RAW" | awk '{print $3}'); if [[ -n "$SWAP_TOTAL_RAW" && "$SWAP_TOTAL_RAW" -ne 0 ]]; then SWAP_USED_PERCENT=$(( 100 * SWAP_USED_RAW / SWAP_TOTAL_RAW )); else SWAP_USED_PERCENT=0; fi

    # --- Health Status Icons ---
    CRON_STATUS_ICON="❓"; DOCKER_STATUS_ICON="⚪"; NET_STATUS_ICON="❓";
    if command -v systemctl >/dev/null; then if systemctl is-active --quiet cron; then CRON_STATUS_ICON="✅"; else CRON_STATUS_ICON="❌"; fi; else CRON_STATUS_ICON="❓"; fi
    if command -v docker >/dev/null; then if systemctl is-active --quiet docker 2>/dev/null; then DOCKER_STATUS_ICON="✅"; else DOCKER_STATUS_ICON="❌"; fi; fi
    if command -v ping >/dev/null; then if ping -c 1 -W 1 8.8.8.8 > /dev/null 2>&1; then NET_STATUS_ICON="✅"; else NET_STATUS_ICON="❌"; fi; fi

    # Export needed vars
    export DISK_PERCENT MEM_USED_PERCENT SWAP_USAGE SWAP_USED_PERCENT SWAP_TOTAL_RAW CRON_STATUS_ICON DOCKER_STATUS_ICON NET_STATUS_ICON CPU_MODEL CPU_CORES CPU_FREQ MEM_USAGE DISK_USAGE UPTIME OS_VERSION
}

get_traffic_status() {
    load_traffic_config >/dev/null 2>&1
    if [[ "$ENABLE_TRAFFIC_MONITOR" == "true" ]]; then
        DATA=$(vnstat -i "$(ip route get 8.8.8.8 | awk '{print $5; exit}')" --oneline 2>/dev/null)
        TRAFFIC_RX_MIB=$(echo "$DATA" | cut -d ';' -f 9 | tr -d ' ' | sed 's/GiB/*1024/;s/TiB/*1024*1024/;s/MiB//;s/KiB/\/1024/' | bc -l 2>/dev/null || echo 0)
        TRAFFIC_TX_MIB=$(echo "$DATA" | cut -d ';' -f 10 | tr -d ' ' | sed 's/GiB/*1024/;s/TiB/*1024*1024/;s/MiB//;s/KiB/\/1024/' | bc -l 2>/dev/null || echo 0)
        TRAFFIC_TOTAL_MIB=$(echo "$TRAFFIC_RX_MIB + $TRAFFIC_TX_MIB" | bc)
        TRAFFIC_TOTAL_GB=$(echo "scale=2; $TRAFFIC_TOTAL_MIB / 1024" | bc)
        if [[ "$ENABLE_LIMIT" == "true" && "$LIMIT_GB" -gt 0 ]]; then
            LIMIT_MIB=$(echo "$LIMIT_GB * 1024" | bc)
            TRAFFIC_PERCENT=$(echo "scale=2; ($TRAFFIC_TOTAL_MIB / $LIMIT_MIB) * 100" | bc)
        else
            TRAFFIC_PERCENT=0
        fi
    else
        TRAFFIC_TOTAL_GB=0
        TRAFFIC_PERCENT=0
    fi
    export TRAFFIC_TOTAL_GB TRAFFIC_PERCENT THRESHOLD_1 THRESHOLD_2 THRESHOLD_3
}

view_status() {
    clear_cmd; echo -e "\033[34m 📊 任务状态信息 ▍\033[0m";
    echo -e "\n\033[36mℹ️  脚本信息 ▍\033[0m";
    printf "  %-16s: %s\n" "当前版本" "$CURRENT_VERSION"; printf "  %-16s: %s\n" "优化脚本" "$SCRIPT_PATH"; printf "  %-16s: %s\n" "日志文件" "$LOG_FILE"; local log_size; log_size=$(du -sh "$LOG_FILE" 2>/dev/null || echo '未知'); printf "  %-16s: %s\n" "日志大小" "$log_size"; if [ -f "$SCRIPT_PATH" ]; then printf "  %-16s: ✅ 已安装\n" "安装状态"; local itime; itime=$(stat -c %Y "$SCRIPT_PATH" 2>/dev/null); if [ -n "$itime" ]; then printf "  %-16s: %s\n" "安装时间" "$(date -d "@$itime" '+%Y-%m-%d %H:%M:%S')"; fi; else printf "  %-16s: ❌ 未安装\n" "安装状态"; fi;

    echo -e "\n\033[36m🖥️  服务器状态 ▍\033[0m"; get_server_status;
    printf "  %-14s : %s\n" "CPU 型号" "${CPU_MODEL:-未知}"; printf "  %-14s : %s\n" "CPU 核心数" "${CPU_CORES:-?}"; printf "  %-14s : %s MHz\n" "CPU 频率" "${CPU_FREQ:-?}"; printf "  %-14s : %s (%s%% 已用)\n" "内存" "${MEM_USAGE:-?}" "${MEM_USED_PERCENT:-?}"; printf "  %-14s : %s (%s%% 已用)\n" "Swap" "${SWAP_USAGE:-?}" "${SWAP_USED_PERCENT:-?}"; printf "  %-14s : %s (%s%% 已用)\n" "硬盘空间(/)" "${DISK_USAGE:-?}" "${DISK_PERCENT:-?}";
    printf "  %-14s : %s\n" "系统在线时间" "${UPTIME:-未知}"; printf "  %-14s : %s\n" "系统" "${OS_VERSION:-未知}";
    printf "  %-14s : %s Cron | %s Docker | %s Network(v4)\n" "服务简报" "${CRON_STATUS_ICON:-❓}" "${DOCKER_STATUS_ICON:-⚪}" "${NET_STATUS_ICON:-❓}"

    echo -e "\n\033[36m💾 DB客户端 ▍\033[0m"; echo -n "  MySQL: "; if command -v mysqldump >/dev/null; then echo "✅ 已安装 ($(which mysqldump))"; else echo "❌ 未安装"; fi; echo -n "  PostgreSQL: "; if command -v psql >/dev/null && command -v pg_dump >/dev/null; then echo "✅ 已安装 ($(which psql))"; else echo "❌ 未安装"; fi;

    echo -e "\n\033[36m📡 流量监控状态 ▍\033[0m"; get_traffic_status;
    if [[ "$ENABLE_TRAFFIC_MONITOR" == "true" ]]; then
        printf "  %-16s: %s GB\n" "当前流量使用" "$TRAFFIC_TOTAL_GB"
        if [[ "$ENABLE_LIMIT" == "true" && "$LIMIT_GB" -gt 0 ]]; then
            printf "  %-16s: %s GB\n" "流量限制" "$LIMIT_GB"
            printf "  %-16s: %s%%\n" "使用百分比" "$TRAFFIC_PERCENT"
            printf "  %-16s: %s%% / %s%% / %s%%\n" "提醒阈值" "$THRESHOLD_1" "$THRESHOLD_2" "$THRESHOLD_3"
        else
            echo "  流量限制未启用"
        fi
    else
        echo "  流量监控未启用"
    fi

    echo -e "\n\033[36m🗓️  所有计划任务 ▍\033[0m";
    local script_tasks=() system_tasks=() line user command schedule source cron_output f task_entry schedule_str m h dom mon dow task_count=0 short_cmd dbn srcn source_file source_short
    source="User Cron (root)"; cron_output=$(crontab -l 2>/dev/null); if [ -n "$cron_output" ]; then while IFS= read -r line; do if [[ -n "$line" && ! "$line" =~ ^\s*# ]]; then if [[ "$line" =~ ^[0-9\*\/\,-]+ && $(echo "$line" | wc -w) -ge 6 ]]; then task_count=$((task_count + 1)); read -r m h dom mon dow command <<< "$line"; schedule_str=$(format_cron_schedule_human "$m" "$h" "$dom" "$mon" "$dow"); if [[ "$command" == "$SCRIPT_PATH" ]]; then short_cmd="服务器优化任务"; task_entry=$(printf "  %-28s [%s]\n      └─ %s" "$schedule_str" "$source" "$short_cmd"); script_tasks+=("$task_entry"); elif [[ "$command" == *"$TRAFFIC_WRAPPER_SCRIPT"* ]]; then short_cmd="流量监控检查"; task_entry=$(printf "  %-28s [%s]\n      └─ %s" "$schedule_str" "$source" "$short_cmd"); script_tasks+=("$task_entry"); elif [[ "$command" == *"/root/.acme.sh"* ]]; then short_cmd="acme.sh 证书续期"; task_entry=$(printf "  %-28s [%s]\n      └─ %s" "$schedule_str" "$source" "$short_cmd"); system_tasks+=("$task_entry"); else [ ${#command} -gt 60 ] && short_cmd="${command:0:57}..." || short_cmd="$command"; task_entry=$(printf "  %-28s [%s]\n      └─ %s" "$schedule_str" "$source" "$short_cmd"); system_tasks+=("$task_entry"); fi; fi; fi; done <<< "$cron_output"; fi
    source="/etc/crontab"; if [ -f "$source" ]; then while IFS= read -r line; do if [[ -n "$line" && ! "$line" =~ ^\s*# ]]; then if [[ "$line" =~ ^[0-9\*\/\,-]+ && $(echo "$line" | wc -w) -ge 7 ]]; then task_count=$((task_count + 1)); read -r m h dom mon dow user command <<< "$line"; schedule_str=$(format_cron_schedule_human "$m" "$h" "$dom" "$mon" "$dow"); if [[ "$command" == *"/etc/cron.hourly"* ]]; then short_cmd="执行 hourly 任务"; elif [[ "$command" == *"/etc/cron.daily"* ]]; then short_cmd="执行 daily 任务"; elif [[ "$command" == *"/etc/cron.weekly"* ]]; then short_cmd="执行 weekly 任务"; elif [[ "$command" == *"/etc/cron.monthly"* ]]; then short_cmd="执行 monthly 任务"; elif [ ${#command} -gt 50 ]; then short_cmd="${command:0:47}..."; else short_cmd="$command"; fi; task_entry=$(printf "  %-28s [%s]\n      └─ User: %s | Cmd: %s" "$schedule_str" "$source" "$user" "$short_cmd"); system_tasks+=("$task_entry"); fi; fi; done < "$source"; fi
    if [ -d "/etc/cron.d" ]; then for f in /etc/cron.d/*; do if [ -f "$f" ] && [[ ! "$f" =~ (\.bak|\.old|\.disabled|~) ]] ; then source_file=$(basename "$f"); source_short="/etc/cron.d/$source_file"; while IFS= read -r line; do if [[ -n "$line" && ! "$line" =~ ^\s*# ]]; then if [[ "$line" =~ ^[0-9\*\/\,-]+ && $(echo "$line" | wc -w) -ge 7 ]]; then task_count=$((task_count + 1)); read -r m h dom mon dow user command <<< "$line"; schedule_str=$(format_cron_schedule_human "$m" "$h" "$dom" "$mon" "$dow"); if [[ "$f" == "$BACKUP_CRON" ]]; then if [[ "$command" == *"pg_dumpall"* ]]; then short_cmd="PostgreSQL 全部数据库备份"; elif [[ "$command" == *"mysqldump --all-databases"* ]]; then short_cmd="MySQL 全部数据库备份"; elif [[ "$command" == *"pg_dump"* ]]; then dbn=$(echo "$command" | grep -oP "(pg_dump.* '|pg_dump.* )\\K[^' |]+"); [ -n "$dbn" ] && short_cmd="PostgreSQL 备份 '$dbn'" || short_cmd="PostgreSQL 特定DB备份"; elif [[ "$command" == *"mysqldump"* ]]; then dbn=$(echo "$command" | grep -oP "(mysqldump.* '|mysqldump.* )\\K[^' |]+"); [ -n "$dbn" ] && short_cmd="MySQL 备份 '$dbn'" || short_cmd="MySQL 特定DB备份"; elif [[ "$command" == *"tar -czf /tmp/backup_data"* ]]; then srcn=$(echo "$command" | grep -oP "backup_data_\\K[^_]+"); [ -n "$srcn" ] && short_cmd="程序数据备份 ($srcn)" || short_cmd="程序数据备份 (tar)"; else short_cmd="备份任务"; fi; task_entry=$(printf "  %-28s [%s]\n      └─ User: %s | Cmd: %s" "$schedule_str" "$source_short" "$user" "$short_cmd"); script_tasks+=("$task_entry"); elif [[ "$f" == "$TRAFFIC_CRON_FILE" ]]; then short_cmd="流量监控检查"; task_entry=$(printf "  %-28s [%s]\n      └─ User: %s | Cmd: %s" "$schedule_str" "$source_short" "$user" "$short_cmd"); script_tasks+=("$task_entry"); else if [[ "$source_file" == "certbot" ]]; then short_cmd="Certbot 证书续期"; elif [[ "$source_file" == "e2scrub_all" ]]; then short_cmd="e2scrub 文件系统检查"; elif [[ "$source_file" == "ntpsec" ]]; then short_cmd="NTPsec 时间同步维护"; elif [ ${#command} -gt 60 ]; then short_cmd="${command:0:57}..."; else short_cmd="$command"; fi; task_entry=$(printf "  %-28s [%s]\n      └─ User: %s | Cmd: %s" "$schedule_str" "$source_short" "$user" "$short_cmd"); system_tasks+=("$task_entry"); fi; fi; fi; done < "$f"; fi; done; fi

    printf "\n\033[1;35m▌ 脚本配置计划任务 ▍\033[0m\n"
    if [ ${#script_tasks[@]} -gt 0 ]; then printf "%s\n\n" "${script_tasks[@]}"; else echo "    (无)"; fi
    printf "\n\033[1;35m▌ 其他系统计划任务 ▍\033[0m\n"
    if [ ${#system_tasks[@]} -gt 0 ]; then printf "%s\n\n" "${system_tasks[@]}"; else echo "    (无)"; fi
    if [ $task_count -eq 0 ]; then log "未找到有效计划任务"; fi

    echo -e "\n\033[36m🚀 下次计划执行 (本工具配置) ▍\033[0m";
    local optimization_scheduled=false backup_scheduled=false traffic_scheduled=false opt_next_time backup_freq traffic_freq cron_job cmin chr cday ntime
    cron_job=$(crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH"); if [ -n "$cron_job" ]; then optimization_scheduled=true; read -r cmin chr dom mon cday <<<"$(echo "$cron_job" | awk '{print $1,$2,$3,$4,$5}')"; opt_next_time=$(get_next_cron_time "$cmin" "$chr" "$cday"); printf "  %-18s: %s (%s)\n" "优化任务下次执行" "$opt_next_time" "$(format_cron_schedule_human "$cmin" "$chr" "$dom" "$mon" "$cday")"; else printf "  %-18s: %s\n" "优化任务" "未设置"; fi
    if [ -f "$BACKUP_CRON" ] && grep -qE '[^[:space:]]' "$BACKUP_CRON"; then backup_scheduled=true; read -r cmin chr dom mon cday user command <<< "$(grep -vE '^\s*#|^$' "$BACKUP_CRON" | head -n 1)"; backup_freq=$(format_cron_schedule_human "$cmin" "$chr" "$dom" "$mon" "$cday"); printf "  %-18s: %s\n" "备份任务计划" "$backup_freq"; else printf "  %-18s: %s\n" "备份任务计划" "未设置"; fi
    if [ -f "$TRAFFIC_CRON_FILE" ] && grep -qE '[^[:space:]]' "$TRAFFIC_CRON_FILE"; then traffic_scheduled=true; read -r cmin chr dom mon cday user command <<< "$(grep -vE '^\s*#|^$' "$TRAFFIC_CRON_FILE" | head -n 1)"; traffic_freq=$(format_cron_schedule_human "$cmin" "$chr" "$dom" "$mon" "$cday"); printf "  %-18s: %s\n" "流量监控计划" "$traffic_freq"; else printf "  %-18s: %s\n" "流量监控计划" "未设置"; fi
    if $optimization_scheduled; then echo -e "  \033[2m优化任务内容: 日志/缓存/内核清理等\033[0m"; fi

    echo -e "\n\033[36m🕒 上一次优化任务执行详情 ▍\033[0m";
    if [ -f "$LOG_FILE" ]; then local start_ln end_ln; start_ln=$(grep -n '=== 优化任务开始' "$LOG_FILE" | tail -n 1 | cut -d: -f1); end_ln=$(grep -n '=== 优化任务结束 ===' "$LOG_FILE" | tail -n 1 | cut -d: -f1); if [[ -n "$start_ln" && -n "$end_ln" && "$start_ln" -le "$end_ln" ]]; then local run_log stime etime ssec esec task_info summary unique_tasks=(); run_log=$(sed -n "${start_ln},${end_ln}p" "$LOG_FILE"); stime=$(echo "$run_log"|head -n 1|awk '{print $1" "$2}'); etime=$(echo "$run_log"|tail -n 1|awk '{print $1" "$2}'); printf "  %-10s: %s\n" "开始时间" "$stime"; printf "  %-10s: %s\n" "结束时间" "$etime"; ssec=$(date -d "$stime" +%s 2>/dev/null); esec=$(date -d "$etime" +%s 2>/dev/null); if [[ -n "$ssec" && -n "$esec" && "$esec" -ge "$ssec" ]]; then printf "  %-10s: %s 秒\n" "执行时长" "$((esec-ssec))"; else printf "  %-10s: 无法计算\n" "执行时长"; fi; echo "  任务摘要 (基于日志):"; while IFS= read -r line; do task_info=$(echo "$line" | sed 's/^[0-9-]* [0-9:]* - //'); summary=""; case "$task_info" in "检查优化脚本依赖..."|"依赖检查通过." ) ;; "检查待更新软件包..."|"找到"* ) summary="✅ 检查软件包更新";; "配置脚本日志轮转..."|"脚本日志轮转配置完成." ) summary="✅ 配置脚本日志轮转";; "配置系统日志轮转..."|"系统日志轮转配置完成." ) summary="✅ 配置系统日志轮转";; "清理超过"*|"旧系统日志清理完成." ) summary="✅ 清理旧系统日志";; "配置Docker日志轮转..."|"Docker日志配置完成"* ) summary="✅ 配置Docker日志轮转";; "清理Docker容器日志..."|"Docker容器日志清理完成." ) summary="✅ 清理Docker容器日志";; "清理APT缓存..."|"APT缓存清理完成." ) summary="✅ 清理APT缓存";; "清理旧内核..."|"旧内核清理任务结束."|"无旧内核可清理" ) summary="✅ 清理旧内核";; "清理/tmp目录..."|"临时文件清理完成." ) summary="✅ 清理/tmp目录";; "清理用户缓存..."|"用户缓存清理完成." ) summary="✅ 清理用户缓存";; *"错误"*|*"失败"*|*"警告"*) summary="\033[31m❌ ${task_info}\033[0m";; esac; if [[ -n "$summary" && ! " ${unique_tasks[*]} " =~ " $summary " ]]; then unique_tasks+=("$summary"); fi; done <<< "$(echo "$run_log" | grep -v "===" | grep -v "当前磁盘使用情况")"; if [ ${#unique_tasks[@]} -gt 0 ]; then for task_summary in "${unique_tasks[@]}"; do echo -e "    $task_summary"; done; else echo "    (未解析到明确的任务摘要)"; fi; else echo "  ⚠️  未找到完整的上一次优化任务记录"; fi; else echo "  ⚠️  日志文件不存在"; fi

    echo -e "\n\033[36m💡 优化建议 ▍\033[0m"; local suggestions_found=0; local update_cache_file="/tmp/optimize_status_updates.cache" upgradable_count_cached="?";
    if [[ -z "${DISK_PERCENT:-}" || -z "${MEM_USED_PERCENT:-}" || -z "${SWAP_USED_PERCENT:-}" ]]; then get_server_status; fi
    if [[ -n "$DISK_PERCENT" && "$DISK_PERCENT" -gt 85 ]]; then echo -e "  ⚠️  磁盘(/) > 85% ($DISK_PERCENT%), 建议清理或扩容。"; suggestions_found=1; fi
    if [[ -n "$MEM_USED_PERCENT" && "$MEM_USED_PERCENT" -gt 90 ]]; then echo -e "  ⚠️  内存 > 90% ($MEM_USED_PERCENT%), 建议检查进程。"; suggestions_found=1; fi
    if [[ "${SWAP_USAGE}" != "未启用" && -n "$SWAP_USED_PERCENT" && "$SWAP_USED_PERCENT" -gt 30 ]]; then echo -e "  ⚠️  Swap > 30% ($SWAP_USED_PERCENT%), 可能内存不足。"; suggestions_found=1; fi
    if [ ! -f "$SCRIPT_PATH" ]; then echo -e "  ℹ️  优化脚本未安装, 运行选项 1。"; suggestions_found=1; elif ! crontab -l 2>/dev/null | grep -Fq "$SCRIPT_PATH"; then echo -e "  ℹ️  优化脚本未计划, 运行选项 1。"; suggestions_found=1; fi
    if [ ! -f "$CONFIG_FILE" ] || [ ! -f "$BACKUP_CRON" ] || ! grep -qE '[^[:space:]]' "$BACKUP_CRON" 2>/dev/null ; then echo -e "  ℹ️  备份未配置/计划, 运行选项 6 -> 4。"; suggestions_found=1; fi
    if [[ "$ENABLE_TRAFFIC_MONITOR" == "true" ]]; then
        if [[ "$ENABLE_LIMIT" == "true" && "$LIMIT_GB" -gt 0 ]]; then
            if (( $(echo "$TRAFFIC_PERCENT > $THRESHOLD_1" | bc -l) )) && [ "$THRESHOLD_1" -gt 0 ]; then
                echo -e "  ⚠️  流量使用率 $TRAFFIC_PERCENT% 超过阈值 1 ($THRESHOLD_1%)"; suggestions_found=1;
            fi
            if (( $(echo "$TRAFFIC_PERCENT > $THRESHOLD_2" | bc -l) )) && [ "$THRESHOLD_2" -gt 0 ]; then
                echo -e "  ⚠️  流量使用率 $TRAFFIC_PERCENT% 超过阈值 2 ($THRESHOLD_2%)"; suggestions_found=1;
            fi
            if (( $(echo "$TRAFFIC_PERCENT > $THRESHOLD_3" | bc -l) )) && [ "$THRESHOLD_3" -gt 0 ]; then
                echo -e "  ⚠️  流量使用率 $TRAFFIC_PERCENT% 超过阈值 3 ($THRESHOLD_3%)"; suggestions_found=1;
            fi
            if (( $(echo "$TRAFFIC_PERCENT > 100" | bc -l) )); then
                echo -e "  ❌  流量已超限 ($TRAFFIC_TOTAL_GB GB / $LIMIT_GB GB)"; suggestions_found=1;
            elif (( $(echo "$TRAFFIC_PERCENT > 80" | bc -l) )); then
                echo -e "  ℹ️  流量使用率 $TRAFFIC_PERCENT%, 接近限制 $LIMIT_GB GB"; suggestions_found=1;
            else
                echo -e "  ℹ️  流量使用率 $TRAFFIC_PERCENT%, 当前限制 $LIMIT_GB GB"; suggestions_found=1;
            fi
        else
            echo -e "  ℹ️  流量监控启用但未设置限制, 当前使用 $TRAFFIC_TOTAL_GB GB"; suggestions_found=1;
        fi
    else
        echo -e "  ℹ️  流量监控未启用, 运行选项 6 -> 6 配置"; suggestions_found=1;
    fi
    if [ -f "$update_cache_file" ]; then source "$update_cache_file" || upgradable_count_cached="Error"; upgradable_count_cached=${UPGRADABLE_COUNT:-0}; else upgradable_count_cached="未检查"; fi
    if [[ "$upgradable_count_cached" =~ ^[0-9]+$ && "$upgradable_count_cached" -gt 0 ]]; then echo -e "  ℹ️  发现 \033[33m$upgradable_count_cached\033[0m 个待更新软件包 (上次检查时), 建议运行: \033[32msudo apt update && sudo apt upgrade\033[0m"; suggestions_found=1; elif [[ "$upgradable_count_cached" == "Error" ]]; then echo -e "  ⚠️  上次检查软件包更新时出错, 请手动运行 \033[32msudo apt update\033[0m 检查。"; suggestions_found=1; elif [[ "$upgradable_count_cached" == "N/A" ]]; then echo -e "  ℹ️  无法检查软件包更新 (apt-get 未找到?)。"; fi
    if [ -f "$LOG_FILE" ]; then recent_errors=$(grep -E "$(date +%Y-%m-%d).*(ERROR|FAIL|错误|失败)" "$LOG_FILE" | tail -n 3); if [ -n "$recent_errors" ]; then echo -e "  ❌  日志中发现近期错误, 请检查 $LOG_FILE"; suggestions_found=1; fi; fi
    if [ $suggestions_found -eq 0 ]; then echo -e "  ✅  暂无明显问题建议。"; fi

    echo -e "\033[34m▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀\033[0m";
    read -p "按回车返回主菜单..."
}