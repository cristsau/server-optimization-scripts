#!/bin/bash
# lib_utils.sh - Utility functions

# --- Robustness Settings ---
set -uo pipefail # Exit on unset variables, fail pipelines on error

# --- Variables needed by multiple modules (Assume sourced from main script) ---
# LOG_FILE, SCRIPT_PATH etc. are expected to be exported by the main script

# --- Functions ---
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local log_dir
  log_dir=$(dirname "$LOG_FILE")
  if [ ! -d "$log_dir" ]; then mkdir -p "$log_dir" || echo "Warning: Cannot create log directory $log_dir" >&2; fi
  if [ ! -w "$LOG_FILE" ] && ! touch "$LOG_FILE" >/dev/null 2>&1; then
      echo "Error: Cannot write to log file $LOG_FILE" >&2
      echo "$timestamp - $1 [LOG WRITE FAILED]" >&2
      return 1
  fi
  echo "$timestamp - $1" | tee -a "$LOG_FILE"
}

clear_cmd() {
    if command -v tput >/dev/null 2>&1 && tput clear >/dev/null 2>&1; then
        tput clear
    else
        printf "\033[H\033[2J"
    fi
}

check_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "错误: 缺少必需命令 '$cmd'"
        echo -e "\033[31m错误: 缺少必需命令 '$cmd', 请先安装。\033[0m"
        return 1
    fi
    return 0
}

check_main_dependencies() {
    log "检查主脚本核心依赖..."
    local missing_deps=()
    local core_deps=("bash" "curl" "grep" "sed" "awk" "date" "stat" "chmod" "readlink" "dirname" "basename" "find" "rm" "mv" "cp" "tee" "id" "crontab" "wget" "tar" "gzip" "df" "lscpu" "nproc" "free" "uptime" "lsb_release" "which" "tput" "read" "echo" "cat" "tail" "source" "uname" "dpkg" "apt-get" "ln" "sysctl" "cut" "sort" "head" "nl" "timeout")

    for dep in "${core_deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
             if [[ "$dep" == "psql" || "$dep" == "pg_dump" || "$dep" == "pg_dumpall" || "$dep" == "mysql" || "$dep" == "mysqldump" || "$dep" == "jq" || "$dep" == "docker" || "$dep" == "sshpass" || "$dep" == "lftp" || "$dep" == "nc" ]]; then continue; fi
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "\033[31m✗ 主脚本缺少核心依赖:"
        printf "  - %s\n" "${missing_deps[@]}"
        echo -e "\033[0m"
        check_command "apt-get" || exit 1

        read -p "是否尝试自动安装?(y/N): " install_confirm
        if [[ "$install_confirm" == "y" || "$install_confirm" == "Y" ]]; then
            echo "尝试安装: ${missing_deps[*]} ..."
            apt-get update -y || { echo -e "\033[31m✗ apt-get update 失败。\033[0m"; exit 1; }
            local other_deps=() coreutils_needed=false
            for dep in "${missing_deps[@]}"; do if [[ "$dep" == "timeout" ]]; then coreutils_needed=true; else other_deps+=("$dep"); fi; done
            if $coreutils_needed; then apt-get install -y coreutils || { echo -e "\033[31m✗ coreutils 安装失败。\033[0m"; exit 1; }; fi
            if [ ${#other_deps[@]} -gt 0 ]; then apt-get install -y "${other_deps[@]}" || { echo -e "\033[31m✗ 依赖安装失败。\033[0m"; exit 1; }; fi
            echo -e "\033[32m✔ 依赖安装尝试完成。\033[0m";
            local verify_missing=(); for dep in "${missing_deps[@]}"; do if ! command -v "$dep" >/dev/null 2>&1; then verify_missing+=("$dep"); fi; done
            if [ ${#verify_missing[@]} -gt 0 ]; then echo -e "\033[31m✗ 安装后仍缺少: ${verify_missing[*]}。\033[0m"; exit 1; fi
        else echo "用户取消安装。脚本退出。"; exit 1; fi
    else log "主脚本核心依赖检查通过。"; echo -e "\033[32m✔ 主脚本核心依赖检查通过。\033[0m"; fi
}

convert_weekday() {
    local input=$1
    if [ "$input" = "*" ]; then echo "每天";
    elif [ "$input" = "*/2" ]; then echo "每隔一天";
    elif [[ "$input" =~ ^[0-6]$ ]]; then case $input in 0) echo "周日";; 1) echo "周一";; 2) echo "周二";; 3) echo "周三";; 4) echo "周四";; 5) echo "周五";; 6) echo "周六";; esac
    elif [[ "$input" =~ ^[0-6](,[0-6])+$ ]]; then local days_str=""; IFS=',' read -ra days <<< "$input"; for day_num in "${days[@]}"; do case $day_num in 0) days_str+="日,";; 1) days_str+="一,";; 2) days_str+="二,";; 3) days_str+="三,";; 4) days_str+="四,";; 5) days_str+="五,";; 6) days_str+="六,";; esac; done; echo "每周${days_str%,}";
    else echo "未知($input)"; fi
}

get_next_cron_time() {
   local minute=$1 hour=$2 day_of_week=$3 now target_dow current_dow days_ahead next_time temp_time next_run_time=0; now=$(date +%s); if [[ -z "$minute" || -z "$hour" || -z "$day_of_week" ]]; then echo "无效时间参数"; return 1; fi
   if [[ "$day_of_week" == *,* ]]; then IFS=',' read -ra days <<< "$day_of_week"; for target_dow in "${days[@]}"; do if [[ ! "$target_dow" =~ ^[0-6]$ ]]; then continue; fi; current_dow=$(date +%w); days_ahead=$(( (target_dow - current_dow + 7) % 7 )); if [ $days_ahead -eq 0 ] && [ "$(date +%H%M)" -ge "$(printf "%02d%02d" "$hour" "$minute")" ]; then days_ahead=7; fi; temp_time=$(date -d "$days_ahead days $hour:$minute" +%s 2>/dev/null); if [[ $? -eq 0 ]] && { [ $next_run_time -eq 0 ] || [ $temp_time -lt $next_run_time ]; }; then next_run_time=$temp_time; fi; done; if [ $next_run_time -ne 0 ]; then next_time=$next_run_time; else echo "无法计算复杂Cron"; return 1; fi;
   elif [ "$day_of_week" = "*" ]; then local today_exec_time; today_exec_time=$(date -d "today $hour:$minute" +%s 2>/dev/null); if [ $? -ne 0 ]; then echo "日期计算错误"; return 1; fi; if [ "$now" -lt "$today_exec_time" ]; then next_time=$today_exec_time; else next_time=$(date -d "tomorrow $hour:$minute" +%s 2>/dev/null); fi;
   elif [ "$day_of_week" = "*/2" ]; then local current_dom today_exec_time; current_dom=$(date +%d); today_exec_time=$(date -d "today $hour:$minute" +%s 2>/dev/null); if [ $? -ne 0 ]; then echo "日期计算错误"; return 1; fi; if [ $((current_dom % 2)) -eq 0 ]; then if [ $now -lt $today_exec_time ]; then next_time=$today_exec_time; else next_time=$(date -d "+2 days $hour:$minute" +%s 2>/dev/null); fi; else next_time=$(date -d "tomorrow $hour:$minute" +%s 2>/dev/null); fi;
   elif [[ "$day_of_week" =~ ^[0-6]$ ]]; then target_dow=$day_of_week; current_dow=$(date +%w); days_ahead=$(( (target_dow - current_dow + 7) % 7 )); if [ $days_ahead -eq 0 ] && [ "$(date +%H%M)" -ge "$(printf "%02d%02d" "$hour" "$minute")" ]; then days_ahead=7; fi; next_time=$(date -d "$days_ahead days $hour:$minute" +%s 2>/dev/null);
   else echo "不支持的Cron星期: $day_of_week"; return 1; fi
   if [[ -n "$next_time" ]] && [[ "$next_time" =~ ^[0-9]+$ ]]; then echo "$(date -d "@$next_time" '+%Y-%m-%d %H:%M:%S')"; else echo "无法计算下次时间"; return 1; fi
}

# Input validation helpers
validate_numeric() {
    local value="$1" name="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then echo -e "\033[31m错误: '$name' 必须是数字。\033[0m"; return 1; fi; return 0;
}
validate_path_exists() {
    local path="$1" type="$2"; if [ ! -$type "$path" ]; then echo -e "\033[31m错误: 路径 '$path' 不存在或类型不符。\033[0m"; return 1; fi; return 0;
}

# Manage optimization script cron job
manage_cron() {
    # Needs SCRIPT_PATH (exported from main), convert_weekday (in this file), log (in this file)
    log "管理优化任务 Cron: 参数数量 $#"
    local temp_cronfile exit_code cron_line hour day_of_week
    temp_cronfile=$(mktemp) || { log "错误: 无法创建临时文件 for crontab"; return 1; }

    crontab -l > "$temp_cronfile" 2>/dev/null
    grep -vF "$SCRIPT_PATH" "$temp_cronfile" > "${temp_cronfile}.tmp" || true

    if [ $# -eq 2 ]; then
        hour="$1"; day_of_week="$2"
        # Basic validation
        if [[ ! "$hour" =~ ^([0-9]|1[0-9]|2[0-3])$ || ! ( "$day_of_week" =~ ^[0-6*]$ || "$day_of_week" =~ ^[0-6](,[0-6])+$ || "$day_of_week" == "*/2" ) ]]; then
             log "错误: manage_cron 收到无效时间参数 hour='$hour' day='$day_of_week'"
             rm -f "$temp_cronfile" "${temp_cronfile}.tmp"
             return 1
        fi
        cron_line="0 $hour * * $day_of_week $SCRIPT_PATH"
        echo "$cron_line" >> "${temp_cronfile}.tmp"
        log "准备添加/更新优化任务: $cron_line"
    else
        log "准备移除优化任务"
    fi

    crontab "${temp_cronfile}.tmp"
    exit_code=$?
    rm -f "$temp_cronfile" "${temp_cronfile}.tmp"

    if [ $exit_code -ne 0 ]; then log "错误: 更新 crontab 失败 (代码: $exit_code)"; return 1; fi
    if [ $# -eq 2 ]; then log "设置/更新优化任务成功: 每周 $(convert_weekday "$2") $1:00";
    else log "移除优化任务计划成功"; fi
    return 0
}
