#!/bin/bash
# 脚本名称：setup_optimize_server.sh
# 作者：cristsau
# 版本：10.0 (改进状态显示, 修复错误, 移除流媒体)
# 功能：服务器优化管理工具
# 注意：请确保使用 Unix (LF) 换行符保存此文件，并使用 UTF-8 编码。

# --- 全局变量 ---
SCRIPT_NAME="optimize_server.sh"
SCRIPT_PATH="/usr/local/bin/$SCRIPT_NAME"
LOG_FILE="/var/log/optimize_server.log"
TEMP_LOG="/tmp/optimize_temp.log"
CURRENT_VERSION="6.3"
BACKUP_CRON="/etc/cron.d/backup_cron"
CONFIG_FILE="/etc/backup.conf"

# --- 基础函数 ---

# 日志记录
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  # 确保日志目录存在且可写
  local log_dir
  log_dir=$(dirname "$LOG_FILE")
  if [ ! -d "$log_dir" ]; then mkdir -p "$log_dir" || echo "Warning: Cannot create log directory $log_dir" >&2; fi
  if [ ! -w "$log_dir" ]; then echo "Warning: Log directory $log_dir not writable" >&2; fi
  echo "$timestamp - $1" | tee -a "$LOG_FILE"
}

# 清屏函数 (全局定义)
clear_cmd() {
    if command -v tput >/dev/null 2>&1 && tput clear >/dev/null 2>&1; then
        tput clear
    else
        printf "\033[H\033[2J" # POSIX fallback
    fi
}

# 检查主脚本依赖 (含交互式安装)
check_main_dependencies() {
    local missing_deps=()
    # 核心依赖列表
    local core_deps=("bash" "curl" "grep" "sed" "awk" "date" "stat" "chmod" "readlink" "dirname" "basename" "find" "rm" "mv" "cp" "tee" "id" "crontab" "wget" "tar" "gzip" "df" "lscpu" "nproc" "free" "uptime" "lsb_release" "which" "tput" "read" "echo" "cat" "tail" "source" "uname" "dpkg" "apt-get" "ln" "sysctl" "cut" "sort" "head" "nl" "timeout")

    echo "检查主脚本核心依赖..."
    for dep in "${core_deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
             # 允许可选工具缺失
             if [[ "$dep" == "psql" || "$dep" == "pg_dump" || "$dep" == "pg_dumpall" || "$dep" == "mysql" || "$dep" == "mysqldump" || "$dep" == "jq" || "$dep" == "docker" || "$dep" == "sshpass" || "$dep" == "lftp" || "$dep" == "nc" ]]; then
                continue
             fi
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "\033[31m✗ 主脚本缺少核心依赖:"
        printf "  - %s\n" "${missing_deps[@]}"
        echo -e "\033[0m"
        if ! command -v apt-get >/dev/null 2>&1; then echo -e "\033[31mapt-get缺失,无法自动安装。\033[0m"; exit 1; fi

        read -p "是否尝试自动安装?(y/N): " install_confirm
        if [[ "$install_confirm" == "y" || "$install_confirm" == "Y" ]]; then
            echo "尝试安装: ${missing_deps[*]} ..."
            apt-get update -y || { echo -e "\033[31m✗ apt-get update 失败。\033[0m"; exit 1; }
            local other_deps=() coreutils_needed=false
            for dep in "${missing_deps[@]}"; do
                if [[ "$dep" == "timeout" ]]; then coreutils_needed=true; else other_deps+=("$dep"); fi
            done
            if $coreutils_needed; then apt-get install -y coreutils || { echo -e "\033[31m✗ coreutils 安装失败。\033[0m"; exit 1; }; fi
            if [ ${#other_deps[@]} -gt 0 ]; then apt-get install -y "${other_deps[@]}" || { echo -e "\033[31m✗ 依赖安装失败。\033[0m"; exit 1; }; fi

            echo -e "\033[32m✔ 依赖安装尝试完成。\033[0m";
            local verify_missing=(); for dep in "${missing_deps[@]}"; do if ! command -v "$dep" >/dev/null 2>&1; then verify_missing+=("$dep"); fi; done
            if [ ${#verify_missing[@]} -gt 0 ]; then echo -e "\033[31m✗ 安装后仍缺少: ${verify_missing[*]}。\033[0m"; exit 1; fi
        else echo "用户取消安装。脚本退出。"; exit 1; fi
    else echo -e "\033[32m✔ 主脚本核心依赖检查通过。\033[0m"; fi
}

# 配置主脚本日志轮转
setup_main_logrotate() {
    local logrotate_conf="/etc/logrotate.d/setup_optimize_server_main"
    echo "配置主脚本日志轮转: $logrotate_conf ..."
    cat > "$logrotate_conf" <<EOF
$LOG_FILE {
    rotate 4
    weekly
    size 10M # 如果周期间隔内超过10M也轮转
    missingok
    notifempty
    delaycompress
    compress
    copytruncate # 复制并清空，比重启服务更安全
}
EOF
    if [ $? -eq 0 ]; then
        log "主脚本日志轮转配置成功: $logrotate_conf"
        echo "主脚本日志轮转配置成功。"
    else
        log "错误: 无法写入主脚本日志轮转配置 $logrotate_conf"
        echo -e "\033[31m错误: 无法写入主脚本日志轮转配置 $logrotate_conf\033[0m"
    fi
}


# 转换星期
convert_weekday() {
    local input=$1
    if [ "$input" = "*" ]; then echo "每天";
    elif [ "$input" = "*/2" ]; then echo "每隔一天";
    elif [[ "$input" =~ ^[0-6]$ ]]; then case $input in 0) echo "周日";; 1) echo "周一";; 2) echo "周二";; 3) echo "周三";; 4) echo "周四";; 5) echo "周五";; 6) echo "周六";; esac
    elif [[ "$input" =~ ^[0-6](,[0-6])+$ ]]; then local days_str=""; IFS=',' read -ra days <<< "$input"; for day_num in "${days[@]}"; do case $day_num in 0) days_str+="日,";; 1) days_str+="一,";; 2) days_str+="二,";; 3) days_str+="三,";; 4) days_str+="四,";; 5) days_str+="五,";; 6) days_str+="六,";; esac; done; echo "每周${days_str%,}";
    else echo "未知($input)"; fi
}

# 管理优化Cron
manage_cron() {
    local temp_cronfile; temp_cronfile=$(mktemp) || { log "错误:无法创建临时文件"; return 1; }
    crontab -l > "$temp_cronfile" 2>/dev/null
    grep -vF "$SCRIPT_PATH" "$temp_cronfile" > "${temp_cronfile}.tmp" || true
    if [ $# -eq 2 ]; then echo "0 $1 * * $2 $SCRIPT_PATH" >> "${temp_cronfile}.tmp"; fi
    crontab "${temp_cronfile}.tmp"
    local exit_code=$?
    rm -f "$temp_cronfile" "${temp_cronfile}.tmp"

    if [ $exit_code -ne 0 ]; then log "错误:更新crontab失败"; return 1; fi
    if [ $# -eq 2 ]; then log "设置/更新优化任务:每周 $(convert_weekday "$2") $1:00";
    else log "移除优化任务计划"; fi
    return 0
}

# 加载备份配置
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    ( source "$CONFIG_FILE" >/dev/null 2>&1 )
    if [ $? -eq 0 ]; then
        source "$CONFIG_FILE"; log "加载配置: $CONFIG_FILE"; return 0;
    else log "错误:加载无效配置 $CONFIG_FILE"; echo -e "\033[31m✗ 加载配置失败\033[0m"; return 1; fi
  else return 1; fi
}

# 创建备份配置
create_config() {
   echo -e "\033[36m▶ 创建备份配置文件 ($CONFIG_FILE)...\033[0m"
   if [ -f "$CONFIG_FILE" ]; then read -p "配置已存在,覆盖?(y/N): " ovw; if [[ "$ovw" != "y" && "$ovw" != "Y" ]]; then echo "取消创建"; return 1; fi; fi
   read -p "DB类型(mysql/postgres): " DB_TYPE
   read -p "DB主机[127.0.0.1]: " DB_HOST; DB_HOST=${DB_HOST:-127.0.0.1}
   case "$DB_TYPE" in
     mysql) read -p "DB端口[3306]: " DB_PORT; DB_PORT=${DB_PORT:-3306};;
     postgres) read -p "DB端口[5432]: " DB_PORT; DB_PORT=${DB_PORT:-5432};;
     *) echo "类型错误"; return 1;;
   esac
   read -p "DB用户: " DB_USER
   read -s -p "DB密码: " DB_PASS; echo
   read -e -p "备份目标路径(本地/http/ftp/sftp/scp/rsync): " TARGET_PATH
   read -p "目标用户(可选): " TARGET_USER
   read -s -p "目标密码/密钥(可选): " TARGET_PASS; echo
   if [[ -z "$DB_TYPE" || -z "$DB_HOST" || -z "$DB_PORT" || -z "$DB_USER" || -z "$TARGET_PATH" ]]; then echo "必填项不能为空"; return 1; fi
   if [[ -n "$TARGET_USER" && -z "$TARGET_PASS" ]]; then echo -e "\033[33m警告:指定用户但无密码/密钥\033[0m"; fi

   cat > "$CONFIG_FILE" <<EOF
# 数据库配置 (Generated: $(date))
DB_TYPE="$DB_TYPE"
DB_HOST="$DB_HOST"
DB_PORT="$DB_PORT"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"

# 备份目标配置
TARGET_PATH="$TARGET_PATH"
TARGET_USER="$TARGET_USER"
TARGET_PASS="$TARGET_PASS"
EOF
   if [ $? -eq 0 ]; then chmod 600 "$CONFIG_FILE"; echo "配置创建/更新成功"; log "配置创建/更新成功"; return 0;
   else echo "写入配置失败"; log "写入配置失败"; return 1; fi
}


# 安装优化脚本
install_script() {
  echo -e "\033[36m▶ 开始安装/更新优化脚本...\033[0m"
  while true; do read -p "每周运行天数(0-6, *=每天): " day; read -p "运行小时(0-23): " hour; if [[ ( "$day" =~ ^[0-6]$ || "$day" == "*" ) && "$hour" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then break; else echo "输入无效"; fi; done
  if ! touch "$LOG_FILE" 2>/dev/null; then LOG_FILE="/tmp/setup_optimize_server.log"; echo "警告:无法写入 $LOG_FILE, 日志将保存到 $LOG_FILE" >&2; if ! touch "$LOG_FILE" 2>/dev/null; then echo "错误:无法写入日志文件"; return 1; fi; fi
  chmod 644 "$LOG_FILE"; log "脚本安装/更新开始"

  # --- 开始生成 optimize_server.sh ---
  cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
# Generated by setup_optimize_server.sh v$CURRENT_VERSION on $(date)
if [ "\$(id -u)" -ne 0 ]; then echo "错误：请以 root 权限运行"; exit 1; fi
LOG_FILE="$LOG_FILE"
if ! touch "\$LOG_FILE" 2>/dev/null; then LOG_FILE="/tmp/optimize_server.log.\$(date +%Y%m%d)"; echo "警告：无法写入 \$LOG_FILE，尝试 \$LOG_FILE" >&2; if ! touch "\$LOG_FILE" 2>/dev/null; then echo "错误：无法写入日志文件。" >&2; exit 1; fi; fi
log() { local timestamp; timestamp=\$(date '+%Y-%m-%d %H:%M:%S'); echo "\$timestamp - \$1" | tee -a "\$LOG_FILE"; }
check_dependencies() {
  log "检查优化脚本依赖..."; local missing_deps=(); local deps=("logrotate" "apt-get" "uname" "dpkg" "rm" "find" "tee" "df" "sync" "date" "docker" "grep" "sed" "awk" "free" "lscpu" "nproc" "lsb_release" "stat" "du" "cut" "which" "head" "tail" "jq" "truncate");
  for tool in "\${deps[@]}"; do if ! command -v "\$tool" &> /dev/null; then if [[ "\$tool" == "docker" ]]; then log "警告: Docker 未安装"; elif [[ "\$tool" == "jq" ]]; then log "警告: jq 未安装"; else missing_deps+=("\$tool"); fi; fi; done;
  if [ \${#missing_deps[@]} -gt 0 ]; then log "错误: 缺少依赖: \${missing_deps[*]}"; exit 1; else log "依赖检查通过。"; fi
}
configure_script_logrotate() { log "配置脚本日志轮转..."; cat <<EOL > /etc/logrotate.d/optimize_server
\$LOG_FILE {
    rotate 7
    daily
    missingok
    notifempty
    delaycompress
    compress
    copytruncate
}
EOL
log "脚本日志轮转配置完成。"; }
show_disk_usage() { log "当前磁盘使用情况："; df -h | tee -a "\$LOG_FILE"; }
configure_logrotate() { log "配置系统日志轮转..."; cat <<EOL > /etc/logrotate.d/rsyslog
/var/log/syslog
/var/log/mail.log
/var/log/auth.log
/var/log/kern.log
/var/log/daemon.log
/var/log/messages
/var/log/user.log
/var/log/debug
/var/log/dpkg.log
/var/log/apt/*.log
{
    rotate 4
    weekly
    missingok
    notifempty
    delaycompress
    compress
    sharedscripts
    copytruncate
}
EOL
log "系统日志轮转配置完成。"; }
clean_old_syslogs() { log "清理超过15天的旧系统日志..."; find /var/log -type f \\( -name "*.log.[0-9]" -o -name "*.log.*.gz" -o -name "*.[0-9].gz" \\) -mtime +15 -print -delete >> "\$LOG_FILE" 2>&1; find /var/log -type f -name "*.[1-9]" -mtime +15 -print -delete >> "\$LOG_FILE" 2>&1; find /var/log -type f -name "*.gz" -mtime +15 -print -delete >> "\$LOG_FILE" 2>&1; log "旧系统日志清理完成。"; }
configure_docker_logging() {
    if ! command -v docker &>/dev/null; then log "警告：Docker命令未找到"; return; fi;
    if ! docker info &>/dev/null; then log "警告：Docker服务未运行"; return; fi;
    log "配置Docker日志轮转...";
    DAEMON_JSON="/etc/docker/daemon.json";
    DAEMON_JSON_BACKUP="/etc/docker/daemon.json.bak.\$(date +%Y%m%d%H%M%S)";
    default_json_content='{
      "log-driver": "json-file",
      "log-opts": {
        "max-size": "10m",
        "max-file": "3"
      }
    }'

    if ! command -v jq &>/dev/null; then
        log "警告: jq未安装,尝试覆盖创建";
        if [ -f "\$DAEMON_JSON" ]; then
            cp "\$DAEMON_JSON" "\$DAEMON_JSON_BACKUP" && log "已备份到\$DAEMON_JSON_BACKUP" || log "备份失败: \$DAEMON_JSON_BACKUP";
        fi;
        mkdir -p /etc/docker && echo "\$default_json_content" > "\$DAEMON_JSON" || { log "写入Docker配置失败"; return 1; }
    else
        if [ -f "\$DAEMON_JSON" ]; then
            if jq -e . "\$DAEMON_JSON" > /dev/null 2>&1; then
                log "合并Docker配置";
                cp "\$DAEMON_JSON" "\$DAEMON_JSON_BACKUP" && log "已备份";
                jq --argjson new_opts '{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }' '. + \$new_opts' "\$DAEMON_JSON" > "\$DAEMON_JSON.tmp" && mv "\$DAEMON_JSON.tmp" "\$DAEMON_JSON" || { log "合并失败"; cp "\$DAEMON_JSON_BACKUP" "\$DAEMON_JSON"; return 1; };
            else
                log "警告：\$DAEMON_JSON格式无效,覆盖创建";
                cp "\$DAEMON_JSON" "\$DAEMON_JSON_BACKUP" && log "已备份";
                echo "\$default_json_content" > "\$DAEMON_JSON" || { log "写入Docker配置失败"; return 1; }
            fi
        else
            log "创建Docker配置文件";
            mkdir -p /etc/docker && echo "\$default_json_content" > "\$DAEMON_JSON" || { log "写入Docker配置失败"; return 1; }
        fi
    fi;
    log "Docker日志配置完成,请重启Docker生效。";
}
clean_docker_logs() { if ! command -v docker &>/dev/null; then log "警告：Docker命令未找到"; return; fi; if ! docker info &>/dev/null; then log "警告：Docker服务未运行"; return; fi; log "清理Docker容器日志..."; containers=\$(docker ps -a -q); if [ -z "\$containers" ]; then log "无Docker容器"; return; fi; for container in \$containers; do log_path=\$(docker inspect --format='{{.LogPath}}' "\$container" 2>/dev/null); cname=\$(docker inspect --format='{{.Name}}' "\$container" | sed 's/^\///'); if [ -n "\$log_path" ] && [ -f "\$log_path" ]; then log "清理容器(\$cname)日志..."; truncate -s 0 "\$log_path" && log "清理成功" || log "清理失败"; else log "警告：未找到容器(\$cname)日志"; fi; done; log "Docker容器日志清理完成。"; }
clean_apt_cache() { log "清理APT缓存..."; apt-get clean -y >> "\$LOG_FILE" 2>&1; log "APT缓存清理完成。"; }
clean_old_kernels() { log "清理旧内核..."; current_kernel=\$(uname -r); kernels_to_remove=\$(dpkg --list | grep -E '^ii +linux-(image|headers)-[0-9]' | grep -v "\$current_kernel" | awk '{print \$2}'); if [ -n "\$kernels_to_remove" ]; then log "将移除:"; echo "\$kernels_to_remove" | while read pkg; do log "  - \$pkg"; done; apt-get purge -y \$kernels_to_remove >> "\$LOG_FILE" 2>&1; if [ \$? -eq 0 ]; then log "移除成功,清理残留..."; apt-get autoremove -y >> "\$LOG_FILE" 2>&1; log "残留清理完成"; else log "错误：移除失败"; fi; else log "无旧内核可清理"; fi; log "旧内核清理任务结束。"; }
clean_tmp_files() { log "清理/tmp目录..."; if [ -d /tmp ]; then find /tmp -mindepth 1 -maxdepth 1 ! -name "optimize_temp.log" -exec rm -rf {} \; 2>> "\$LOG_FILE"; log "临时文件清理完成。"; else log "警告：/tmp不存在"; fi; }
clean_user_cache() { log "清理用户缓存..."; find /home/*/.cache -maxdepth 1 -mindepth 1 \\( -type d -exec rm -rf {} \; -o -type f -delete \\) -print >> "\$LOG_FILE" 2>&1; if [ -d /root/.cache ]; then find /root/.cache -maxdepth 1 -mindepth 1 \\( -type d -exec rm -rf {} \; -o -type f -delete \\) -print >> "\$LOG_FILE" 2>&1; log "清理root缓存完成"; fi; log "用户缓存清理完成。"; }
main() { log "=== 优化任务开始 v$CURRENT_VERSION ==="; check_dependencies; show_disk_usage; configure_script_logrotate; configure_logrotate; clean_old_syslogs; configure_docker_logging; clean_docker_logs; clean_apt_cache; clean_old_kernels; clean_tmp_files; clean_user_cache; show_disk_usage; log "=== 优化任务结束 ==="; }
main
EOF
# --- 结束生成 ---

  if [ $? -ne 0 ]; then log "错误:写入优化脚本失败"; echo "写入脚本失败"; return 1; fi
  chmod +x "$SCRIPT_PATH" || { log "错误:设置权限失败"; return 1; }
  manage_cron "$hour" "$day" || { log "错误:设置Cron失败"; return 1; }

  echo -e "\033[36m▶ 正在执行初始化测试...\033[0m"
  if timeout 60s bash "$SCRIPT_PATH"; then
      if tail -n 5 "$LOG_FILE" | grep -q "=== 优化任务结束 ==="; then
         echo -e "\033[32m✔ 安装/更新成功并通过测试。\033[0m"; log "安装/更新验证成功"; return 0;
      else
         echo -e "\033[31m✗ 测试未完成(无结束标记), 检查日志 $LOG_FILE。\033[0m"; tail -n 20 "$LOG_FILE" >&2; log "测试失败(无结束标记)"; return 1;
      fi
  else
    local exit_code=$?
    if [ $exit_code -eq 124 ]; then echo -e "\033[31m✗ 测试执行超时(60s)。\033[0m"; log "测试执行超时";
    else echo -e "\033[31m✗ 测试执行失败(码 $exit_code), 检查日志 $LOG_FILE。\033[0m"; log "测试执行失败(码 $exit_code)"; fi
    tail -n 20 "$LOG_FILE" >&2; return 1;
  fi
}

# 计算下次 Cron 执行时间
get_next_cron_time() {
   local minute=$1 hour=$2 day_of_week=$3 now target_dow current_dow days_ahead next_time temp_time next_run_time=0; now=$(date +%s); if [[ -z "$minute" || -z "$hour" || -z "$day_of_week" ]]; then echo "无效时间参数"; return 1; fi
   if [[ "$day_of_week" == *,* ]]; then IFS=',' read -ra days <<< "$day_of_week"; for target_dow in "${days[@]}"; do if [[ ! "$target_dow" =~ ^[0-6]$ ]]; then continue; fi; current_dow=$(date +%w); days_ahead=$(( (target_dow - current_dow + 7) % 7 )); if [ $days_ahead -eq 0 ] && [ "$(date +%H%M)" -ge "$(printf "%02d%02d" "$hour" "$minute")" ]; then days_ahead=7; fi; temp_time=$(date -d "$days_ahead days $hour:$minute" +%s 2>/dev/null); if [[ $? -eq 0 ]] && { [ $next_run_time -eq 0 ] || [ $temp_time -lt $next_run_time ]; }; then next_run_time=$temp_time; fi; done; if [ $next_run_time -ne 0 ]; then next_time=$next_run_time; else echo "无法计算复杂Cron"; return 1; fi;
   elif [ "$day_of_week" = "*" ]; then local today_exec_time; today_exec_time=$(date -d "today $hour:$minute" +%s 2>/dev/null); if [ $? -ne 0 ]; then echo "日期计算错误"; return 1; fi; if [ "$now" -lt "$today_exec_time" ]; then next_time=$today_exec_time; else next_time=$(date -d "tomorrow $hour:$minute" +%s 2>/dev/null); fi;
   elif [ "$day_of_week" = "*/2" ]; then local current_dom today_exec_time; current_dom=$(date +%d); today_exec_time=$(date -d "today $hour:$minute" +%s 2>/dev/null); if [ $? -ne 0 ]; then echo "日期计算错误"; return 1; fi; if [ $((current_dom % 2)) -eq 0 ]; then if [ $now -lt $today_exec_time ]; then next_time=$today_exec_time; else next_time=$(date -d "+2 days $hour:$minute" +%s 2>/dev/null); fi; else next_time=$(date -d "tomorrow $hour:$minute" +%s 2>/dev/null); fi;
   elif [[ "$day_of_week" =~ ^[0-6]$ ]]; then target_dow=$day_of_week; current_dow=$(date +%w); days_ahead=$(( (target_dow - current_dow + 7) % 7 )); if [ $days_ahead -eq 0 ] && [ "$(date +%H%M)" -ge "$(printf "%02d%02d" "$hour" "$minute")" ]; then days_ahead=7; fi; next_time=$(date -d "$days_ahead days $hour:$minute" +%s 2>/dev/null);
   else echo "不支持的Cron星期: $day_of_week"; return 1; fi
   if [[ -n "$next_time" ]] && [[ "$next_time" =~ ^[0-9]+$ ]]; then echo "$(date -d "@$next_time" '+%Y-%m-%d %H:%M:%S')"; else echo "无法计算下次时间"; return 1; fi
}

# 获取服务器状态 (增加数字解析)
get_server_status() {
  CPU_MODEL=$(lscpu | grep "Model name:" | sed 's/Model name:[[:space:]]*//')
  CPU_CORES=$(nproc)
  CPU_FREQ=$(lscpu | grep "CPU MHz:" | sed 's/CPU MHz:[[:space:]]*//' | awk '{printf "%.0f", $1}')
  [ -z "$CPU_FREQ" ] && CPU_FREQ=$(grep 'cpu MHz' /proc/cpuinfo | head -n1 | sed 's/cpu MHz[[:space:]]*:[[:space:]]*//' | awk '{printf "%.0f", $1}')
  [ -z "$CPU_FREQ" ] && CPU_FREQ="未知"
  MEM_INFO=$(free -m | grep Mem); MEM_USED=$(echo "$MEM_INFO" | awk '{print $3}'); MEM_TOTAL=$(echo "$MEM_INFO" | awk '{print $2}'); MEM_USAGE="${MEM_USED} MiB / ${MEM_TOTAL} MiB"
  SWAP_INFO=$(free -m | grep Swap); SWAP_USED=$(echo "$SWAP_INFO" | awk '{print $3}'); SWAP_TOTAL=$(echo "$SWAP_INFO" | awk '{print $2}')
  if [ "$SWAP_TOTAL" -gt 0 ]; then SWAP_USAGE="${SWAP_USED} MiB / ${SWAP_TOTAL} MiB"; else SWAP_USAGE="未启用"; fi
  DISK_INFO=$(df -h / | grep '/'); DISK_USED=$(echo "$DISK_INFO" | awk '{print $3}'); DISK_TOTAL=$(echo "$DISK_INFO" | awk '{print $2}'); DISK_USAGE="${DISK_USED} / ${DISK_TOTAL}"
  UPTIME=$(uptime -p | sed 's/up //')
  OS_VERSION=$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo "未知操作系统")

  # --- Numeric values for suggestions ---
  DISK_PERCENT=$(df / | grep '/' | awk '{ print $5 }' | sed 's/%//')
  MEM_INFO_RAW=$(free | grep Mem)
  MEM_TOTAL_RAW=$(echo "$MEM_INFO_RAW" | awk '{print $2}')
  MEM_USED_RAW=$(echo "$MEM_INFO_RAW" | awk '{print $3}')
  MEM_FREE_RAW=$(echo "$MEM_INFO_RAW" | awk '{print $4}')
  MEM_BUFFCACHE_RAW=$(echo "$MEM_INFO_RAW" | awk '{print $6}')
  # Calculate available-like metric, prevent division by zero
  if [[ -n "$MEM_TOTAL_RAW" && "$MEM_TOTAL_RAW" -ne 0 ]]; then
      MEM_AVAILABLE_RAW=$((MEM_FREE_RAW + MEM_BUFFCACHE_RAW))
      MEM_USED_PERCENT=$(( 100 * (MEM_TOTAL_RAW - MEM_AVAILABLE_RAW) / MEM_TOTAL_RAW ))
  else
      MEM_USED_PERCENT=0
  fi

  SWAP_INFO_RAW=$(free | grep Swap)
  SWAP_TOTAL_RAW=$(echo "$SWAP_INFO_RAW" | awk '{print $2}')
  SWAP_USED_RAW=$(echo "$SWAP_INFO_RAW" | awk '{print $3}')
  if [[ -n "$SWAP_TOTAL_RAW" && "$SWAP_TOTAL_RAW" -ne 0 ]]; then
      SWAP_USED_PERCENT=$(( 100 * SWAP_USED_RAW / SWAP_TOTAL_RAW ))
  else
      SWAP_USED_PERCENT=0
  fi
}

# 查看状态 (增强版)
view_status() {
   clear_cmd; echo -e "\033[34m 📊 任务状态信息 ▍\033[0m"; # Icon added
   echo -e "\n\033[36mℹ️  脚本信息 ▍\033[0m"; # Icon added
   printf "%-16s: %s\n" "当前版本" "$CURRENT_VERSION"; printf "%-16s: %s\n" "优化脚本" "$SCRIPT_PATH"; printf "%-16s: %s\n" "日志文件" "$LOG_FILE"; local log_size; log_size=$(du -sh "$LOG_FILE" 2>/dev/null || echo '未知'); printf "%-16s: %s\n" "日志大小" "$log_size"; if [ -f "$SCRIPT_PATH" ]; then printf "%-16s: ✅ 已安装\n" "安装状态"; local itime; itime=$(stat -c %Y "$SCRIPT_PATH" 2>/dev/null); if [ -n "$itime" ]; then printf "%-16s: %s\n" "安装时间" "$(date -d "@$itime" '+%Y-%m-%d %H:%M:%S')"; fi; else printf "%-16s: ❌ 未安装\n" "安装状态"; fi;

   echo -e "\n\033[36m🖥️  服务器状态 ▍\033[0m"; # Icon added
   get_server_status; printf "%-14s : %s\n" "CPU 型号" "$CPU_MODEL"; printf "%-14s : %s\n" "CPU 核心数" "$CPU_CORES"; printf "%-14s : %s MHz\n" "CPU 频率" "$CPU_FREQ"; printf "%-14s : %s (%s%% 已用)\n" "内存" "$MEM_USAGE" "$MEM_USED_PERCENT"; printf "%-14s : %s (%s%% 已用)\n" "Swap" "$SWAP_USAGE" "$SWAP_USED_PERCENT"; printf "%-14s : %s (%s%% 已用)\n" "硬盘空间(/)" "$DISK_USAGE" "$DISK_PERCENT"; printf "%-14s : %s\n" "系统在线时间" "$UPTIME"; printf "%-14s : %s\n" "系统" "$OS_VERSION";

   echo -e "\n\033[36m💾 DB客户端 ▍\033[0m"; # Icon added
   echo -n "MySQL: "; if command -v mysqldump >/dev/null; then echo "✅ 已安装 ($(which mysqldump))"; else echo "❌ 未安装"; fi;
   echo -n "PostgreSQL: "; if command -v psql >/dev/null && command -v pg_dump >/dev/null; then echo "✅ 已安装 ($(which psql))"; else echo "❌ 未安装"; fi;

   echo -e "\n\033[36m🗓️  计划任务 ▍\033[0m"; # Icon added
   echo "优化任务:"; cron_job=$(crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH"); if [ -n "$cron_job" ]; then cmin=$(echo "$cron_job"|awk '{print $1}'); chr=$(echo "$cron_job"|awk '{print $2}'); cday=$(echo "$cron_job"|awk '{print $5}'); cday_name=$(convert_weekday "$cday"); printf "  %-8s %02d:%02d   执行 %s\n" "$cday_name" "$chr" "$cmin" "$SCRIPT_PATH"; ntime=$(get_next_cron_time "$cmin" "$chr" "$cday"); printf "  %-14s: %s\n" "下次执行" "$ntime"; else echo "  ❌ 未设置优化任务"; fi;
   echo "备份任务:"; backup_task_found=0; if [ -f "$BACKUP_CRON" ]; then while IFS= read -r line; do if [[ -n "$line" && ! "$line" =~ ^\s*# && "$line" =~ ^[0-9*] ]]; then backup_task_found=1; cmin=$(echo "$line"|awk '{print $1}'); chr=$(echo "$line"|awk '{print $2}'); cdayw=$(echo "$line"|awk '{print $5}'); cuser=$(echo "$line"|awk '{print $6}'); ccmd=$(echo "$line"|cut -d' ' -f7-); cday_name=$(convert_weekday "$cdayw"); printf "  %-8s %02d:%02d   由 %-8s 执行\n" "$cday_name" "$chr" "$cmin" "$cuser"; ntime=$(get_next_cron_time "$cmin" "$chr" "$cdayw"); printf "  %-14s: %s\n" "下次执行" "$ntime"; if [[ "$ccmd" =~ mysqldump ]]; then echo "  任务类型: MySQL备份"; elif [[ "$ccmd" =~ pg_dumpall ]]; then echo "  任务类型: PostgreSQL备份(ALL)"; elif [[ "$ccmd" =~ pg_dump ]]; then echo "  任务类型: PostgreSQL备份"; elif [[ "$ccmd" =~ tar ]]; then echo "  任务类型: 文件备份(tar)"; else echo "  任务类型: 未知"; fi; echo ""; fi; done < "$BACKUP_CRON"; if [ $backup_task_found -eq 0 ]; then echo "  ⚠️  文件 $BACKUP_CRON 中无有效任务"; fi; else echo "  ❌ 未设置备份任务 ($BACKUP_CRON不存在)"; fi;

   # --- Next Run Details ---
   echo -e "\n\033[36m🚀 下一次自动优化详情 ▍\033[0m" # Icon added
   cron_job=$(crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH")
   if [ -n "$cron_job" ]; then
      cmin=$(echo "$cron_job"|awk '{print $1}'); chr=$(echo "$cron_job"|awk '{print $2}'); cday=$(echo "$cron_job"|awk '{print $5}')
      ntime=$(get_next_cron_time "$cmin" "$chr" "$cday")
      printf "  %-14s: %s (%s %02d:%02d)\n" "下次执行时间" "$ntime" "$(convert_weekday "$cday")" "$chr" "$cmin"
      echo "  计划执行任务:"
      echo "    ▫️ 检查依赖"
      echo "    ▫️ 配置日志轮转 (脚本 & 系统)"
      echo "    ▫️ 清理旧系统日志 (>15天)"
      echo "    ▫️ 配置/清理 Docker 日志"
      echo "    ▫️ 清理 APT 缓存"
      echo "    ▫️ 清理旧内核"
      echo "    ▫️ 清理 /tmp 目录"
      echo "    ▫️ 清理用户缓存"
   else
      echo -e "  \033[33m⚠️  未设置优化计划任务。\033[0m"
   fi

   # --- Last Run Details (Enhanced) ---
   echo -e "\n\033[36m🕒 上一次任务执行详情 ▍\033[0m" # Icon & Renamed
   if [ -f "$LOG_FILE" ]; then
      local start_ln end_ln
      # Use grep to find line numbers, more robust against version in marker
      start_ln=$(grep -n '=== 优化任务开始' "$LOG_FILE" | tail -n 1 | cut -d: -f1)
      end_ln=$(grep -n '=== 优化任务结束 ===' "$LOG_FILE" | tail -n 1 | cut -d: -f1)

      if [[ -n "$start_ln" && -n "$end_ln" && "$start_ln" -le "$end_ln" ]]; then
          local run_log stime etime ssec esec task_info
          run_log=$(sed -n "${start_ln},${end_ln}p" "$LOG_FILE")
          stime=$(echo "$run_log"|head -n 1|awk '{print $1" "$2}')
          etime=$(echo "$run_log"|tail -n 1|awk '{print $1" "$2}')
          printf "  %-10s: %s\n" "开始时间" "$stime"
          printf "  %-10s: %s\n" "结束时间" "$etime"
          ssec=$(date -d "$stime" +%s 2>/dev/null); esec=$(date -d "$etime" +%s 2>/dev/null)
          if [[ -n "$ssec" && -n "$esec" && "$esec" -ge "$ssec" ]]; then printf "  %-10s: %s 秒\n" "执行时长" "$((esec-ssec))";
          else printf "  %-10s: \033[33m无法计算\033[0m\n" "执行时长"; fi;
          echo "  任务摘要 (基于日志):"
          # Enhanced parsing loop
          echo "$run_log" | grep -v "===" | grep -v "当前磁盘使用情况" | while IFS= read -r line; do
              task_info=$(echo "$line" | sed 's/^[0-9-]* [0-9:]* - //')
              case "$task_info" in
                  "检查优化脚本依赖..." | "依赖检查通过。" ) ;; # Ignore basic dependency check lines
                  "配置脚本日志轮转..." | "脚本日志轮转配置完成。" ) echo "    ✅ 配置脚本日志轮转";;
                  "配置系统日志轮转..." | "系统日志轮转配置完成。" ) echo "    ✅ 配置系统日志轮转";;
                  "清理超过"* | "旧系统日志清理完成。" ) echo "    ✅ 清理旧系统日志";;
                  "配置Docker日志轮转..." | "Docker日志配置完成"* ) echo "    ✅ 配置Docker日志轮转";;
                  "清理Docker容器日志..." | "Docker容器日志清理完成。" ) echo "    ✅ 清理Docker容器日志";;
                  "清理APT缓存..." | "APT缓存清理完成。" ) echo "    ✅ 清理APT缓存";;
                  "清理旧内核..." | "旧内核清理任务结束。" ) echo "    ✅ 清理旧内核";;
                  "清理/tmp目录..." | "临时文件清理完成。" ) echo "    ✅ 清理/tmp目录";;
                  "清理用户缓存..." | "用户缓存清理完成。" ) echo "    ✅ 清理用户缓存";;
                  *"错误"* | *"失败"* | *"警告"*) echo -e "    \033[31m❌ ${task_info}\033[0m";; # Highlight errors/warnings
                  # *) echo "    - $task_info" ;; # Optional: Catch-all for unparsed lines
              esac
          done | sort -u # Sort and make unique
      else echo "  ⚠️  未找到完整的上一次优化任务记录"; fi
   else echo "  ⚠️  日志文件不存在"; fi

   # --- Suggestions Section ---
   echo -e "\n\033[36m💡 优化建议 ▍\033[0m" # Icon added
   local suggestions_found=0
   if [[ -n "$DISK_PERCENT" && "$DISK_PERCENT" -gt 85 ]]; then echo -e "  ⚠️  磁盘(/)使用率 > 85% ($DISK_PERCENT%), 建议清理或扩容。"; suggestions_found=1; fi
   if [[ -n "$MEM_USED_PERCENT" && "$MEM_USED_PERCENT" -gt 90 ]]; then echo -e "  ⚠️  内存使用率 > 90% ($MEM_USED_PERCENT%), 建议检查进程。"; suggestions_found=1; fi
   if [[ "$SWAP_TOTAL_RAW" -gt 0 && -n "$SWAP_USED_PERCENT" && "$SWAP_USED_PERCENT" -gt 30 ]]; then echo -e "  ⚠️  Swap使用率 > 30% ($SWAP_USED_PERCENT%), 可能内存不足。"; suggestions_found=1; fi
   if [ ! -f "$SCRIPT_PATH" ]; then echo -e "  ℹ️  优化脚本未安装, 运行选项 1 安装。"; suggestions_found=1;
   elif ! crontab -l 2>/dev/null | grep -Fq "$SCRIPT_PATH"; then echo -e "  ℹ️  优化脚本未加入计划任务, 运行选项 1 配置。"; suggestions_found=1; fi
   if [ ! -f "$CONFIG_FILE" ] || [ ! -f "$BACKUP_CRON" ] || ! grep -qE '[^[:space:]]' "$BACKUP_CRON" 2>/dev/null ; then echo -e "  ℹ️  备份未配置/计划, 运行选项 6 -> 4 配置。"; suggestions_found=1; fi
   if [ -f "$LOG_FILE" ]; then
      recent_errors=$(grep -E "$(date +%Y-%m-%d).*(ERROR|FAIL|错误|失败)" "$LOG_FILE" | tail -n 3) # Check today's errors
      if [ -n "$recent_errors" ]; then echo -e "  ❌  日志中发现错误/失败记录, 请检查 $LOG_FILE"; suggestions_found=1; fi
   fi
   if [ $suggestions_found -eq 0 ]; then echo -e "  ✅  暂无明显问题建议。"; fi

   echo -e "\033[34m▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀\033[0m";
}

# 安装别名
install_alias() {
   echo -e "\033[36m▶ 快捷命令安装向导\033[0m"; read -p "命令名(默认cristsau): " cmd; cmd=${cmd:-cristsau}; if ! [[ "$cmd" =~ ^[a-zA-Z0-9_-]+$ ]]; then echo "非法字符"; return 1; fi; current_script_path=$(readlink -f "$0"); if [ -z "$current_script_path" ]; then echo "无法获取脚本路径"; return 1; fi; target_link="/usr/local/bin/$cmd"; ln -sf "$current_script_path" "$target_link" || { echo "创建失败"; log "创建快捷命令 $cmd 失败"; return 1; }; chmod +x "$current_script_path"; echo -e "\033[32m✔ 已创建快捷命令: $cmd -> $current_script_path\033[0m"; log "创建快捷命令 $cmd";
}

# 卸载
uninstall() {
   echo -e "\033[31m▶ 开始卸载...\033[0m"; read -p "确定完全卸载?(y/N): " confirm; if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo "取消"; return; fi; log "开始卸载"; echo "移除优化任务..."; manage_cron || log "移除优化cron失败"; echo "移除备份任务..."; if [ -f "$BACKUP_CRON" ]; then rm -v "$BACKUP_CRON"; log "$BACKUP_CRON已移除"; else echo "跳过"; fi; echo "移除备份配置..."; if [ -f "$CONFIG_FILE" ]; then rm -v "$CONFIG_FILE"; log "$CONFIG_FILE已移除"; else echo "跳过"; fi; echo "移除优化脚本..."; if [ -f "$SCRIPT_PATH" ]; then rm -v "$SCRIPT_PATH"; log "$SCRIPT_PATH已移除"; else echo "跳过"; fi; echo "移除快捷命令..."; find /usr/local/bin/ -type l 2>/dev/null | while read -r link; do target=$(readlink -f "$link" 2>/dev/null); if [[ "$target" == *setup_optimize_server.sh ]]; then echo "移除 $link ..."; rm -v "$link" && log "移除 $link"; fi; done; if [ -L "/usr/local/bin/cristsau" ] && [[ "$(readlink -f "/usr/local/bin/cristsau" 2>/dev/null)" == *setup_optimize_server.sh ]]; then echo "移除 cristsau ..."; rm -v "/usr/local/bin/cristsau" && log "移除 cristsau"; fi; echo -e "\n\033[33m⚠ 日志保留: $LOG_FILE\033[0m"; read -p "是否删除日志?(y/N): " del_log; if [[ "$del_log" == "y" || "$del_log" == "Y" ]]; then if [ -f "$LOG_FILE" ]; then rm -v "$LOG_FILE" && echo "已删除"; fi; fi; echo -e "\033[31m✔ 卸载完成\033[0m"; log "卸载完成"; exit 0;
}


# 更新脚本
update_from_github() {
   echo -e "\033[36m▶ 从 GitHub 更新脚本...\033[0m"; CSD=$(dirname "$(readlink -f "$0")"); CSN=$(basename "$(readlink -f "$0")"); TP="$CSD/$CSN"; GU="https://raw.githubusercontent.com/cristsau/server-optimization-scripts/main/setup_optimize_server.sh"; TF="/tmp/${CSN}.tmp"; echo "当前:$TP"; echo "临时:$TF"; if ! command -v wget > /dev/null; then echo "需要wget"; return 1; fi; echo "下载..."; if ! wget -O "$TF" "$GU" >/dev/null 2>&1; then echo "下载失败"; rm -f "$TF"; return 1; fi; if [ ! -s "$TF" ]; then echo "文件为空"; rm -f "$TF"; return 1; fi; LV=$(grep -m 1 -oP '版本：\K[0-9.]+' "$TF"); CVL=$(grep -m 1 -oP '版本：\K[0-9.]+' "$TP"); if [ -z "$LV" ]; then echo "无法提取版本"; read -p "强制更新?(y/N):" force; if [[ "$force" != "y" && "$force" != "Y" ]]; then rm -f "$TF"; return 1; fi; else echo "当前:$CVL 最新:$LV"; if [ "$CVL" = "$LV" ]; then echo "已是最新"; read -p "强制更新?(y/N):" force; if [ "$force" != "y" && "$force" != "Y" ]; then rm -f "$TF"; return 0; fi; elif [[ "$(printf '%s\n' "$CVL" "$LV" | sort -V | head -n1)" == "$LV" ]]; then echo "当前版本更新"; read -p "覆盖为 $LV ?(y/N):" force_dg; if [ "$force_dg" != "y" && "$force_dg" != "Y" ]; then rm -f "$TF"; return 0; fi; fi; fi; echo "备份..."; cp "$TP" "${TP}.bak" || { echo "备份失败"; rm -f "$TF"; return 1; }; echo "覆盖..."; mv "$TF" "$TP" || { echo "覆盖失败"; cp "${TP}.bak" "$TP"; rm -f "$TF"; return 1; }; chmod +x "$TP"; echo "更新成功: $TP"; echo "请重运行: bash $TP"; log "脚本更新到 $LV"; exec bash "$TP"; exit 0;
}

# 开启 BBR
enable_bbr() {
   echo -e "\033[36m▶ 检查并开启 BBR...\033[0m"; kv=$(uname -r|cut -d- -f1); rv="4.9"; if ! printf '%s\n' "$rv" "$kv" | sort -V -C; then echo "内核($kv)过低"; log "BBR失败:内核低"; return 1; fi; echo "内核 $kv 支持BBR"; ccc=$(sysctl net.ipv4.tcp_congestion_control|awk '{print $3}'); cq=$(sysctl net.core.default_qdisc|awk '{print $3}'); echo "当前拥塞控制:$ccc"; echo "当前队列调度:$cq"; if [[ "$ccc" == "bbr" && "$cq" == "fq" ]]; then echo "BBR+FQ已启用"; fi; echo "应用sysctl...";
   cat > /etc/sysctl.conf <<EOF
# Added by optimize_server script
fs.file-max = 6815744
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 16384 16777216
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
# Uncomment below if forwarding needed
# net.ipv4.ip_forward=1
# net.ipv6.conf.all.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
   if sysctl -p >/dev/null 2>&1; then
      echo "sysctl应用成功"; log "sysctl应用成功"; ccc=$(sysctl net.ipv4.tcp_congestion_control|awk '{print $3}'); cq=$(sysctl net.core.default_qdisc|awk '{print $3}');
      if [[ "$ccc" == "bbr" && "$cq" == "fq" ]]; then echo "BBR+FQ已启用"; log "BBR+FQ启用成功";
      else echo "BBR/FQ未完全启用($ccc, $cq),可能需重启"; log "BBR/FQ未完全启用"; fi;
   else echo "应用sysctl失败"; log "应用sysctl失败"; return 1; fi
}


# 检查备份工具
check_backup_tools() {
   local protocol=$1 tool deps=() missing=() optional_missing=() found=()
   case $protocol in webdav) deps=("curl" "grep" "sed");; ftp) deps=("ftp" "lftp");; sftp) deps=("ssh" "sftp" "sshpass");; scp) deps=("ssh" "scp" "sshpass");; rsync) deps=("ssh" "rsync" "sshpass");; local) deps=();; *) echo "协议错误"; return 1;; esac
   for tool in "${deps[@]}"; do if command -v "$tool" >/dev/null; then found+=("$tool"); else if [[ "$tool" == "lftp" && " ${found[*]} " =~ " ftp " ]]; then continue; elif [[ "$tool" == "ftp" && " ${found[*]} " =~ " lftp " ]]; then continue; elif [[ "$tool" == "sshpass" ]]; then optional_missing+=("$tool"); else missing+=("$tool"); fi; fi; done
   if [ ${#missing[@]} -gt 0 ]; then echo "协议'$protocol'缺少工具: ${missing[*]}"; return 1; fi
   if [ ${#optional_missing[@]} -gt 0 ]; then if [[ "${optional_missing[*]}" == "sshpass" ]]; then echo "提示:未找到sshpass,密码操作可能失败"; fi; fi; return 0;
}

# 上传备份文件
upload_backup() {
  local file=$1
  local target=$2
  local username=$3
  local password=$4
  local filename=$(basename "$file")

  if [[ "$target" =~ ^http ]]; then
    protocol="webdav"
    url="${target%/}/$filename"
  elif [[ "$target" =~ ^ftp ]]; then
    protocol="ftp"
    url="${target%/}/$filename"
  elif [[ "$target" =~ ^sftp ]]; then
    protocol="sftp"
    url="${target%/}/$filename"
  elif [[ "$target" =~ ^rsync ]]; then
    protocol="rsync"
    url="${target%/}/$filename"
  else
    protocol="local"
  fi

  if [ "$protocol" != "local" ]; then
    check_backup_tools "$protocol" || return 1
  fi

  # 在上传前清理远端旧备份文件
  case $protocol in
    webdav)
      echo -e "\033[36m正在清理 WebDAV 旧备份...\033[0m"
      # 获取远端文件列表
      curl -u "$username:$password" -X PROPFIND "${target%/}" -H "Depth: 1" >"$TEMP_LOG" 2>&1
      if [ $? -eq 0 ]; then
        # 提取所有备份文件路径，修复大小写并兼容非 Perl grep
        if command -v grep >/dev/null 2>&1 && grep -P "" /dev/null >/dev/null 2>&1; then
          all_files=$(grep -oP '(?<=<D:href>).*?(?=</D:href>)' "$TEMP_LOG" | grep -E '\.(tar\.gz|sql\.gz)$')
        else
          all_files=$(grep '<D:href>' "$TEMP_LOG" | sed 's|.*<D:href>\(.*\)</D:href>.*|\1|' | grep -E '\.(tar\.gz|sql\.gz)$')
        fi
        echo -e "\033[33m调试：提取的所有备份文件路径：\033[0m"
        echo "$all_files"
        log "WebDAV 提取的所有备份文件路径: $all_files"

        # 提取文件名并排除新文件
        old_files=$(echo "$all_files" | sed 's|.*/||' | grep -v "^${filename}$")
        echo -e "\033[33m调试：旧备份文件列表（old_files）：\033[0m"
        echo "$old_files"
        log "WebDAV 旧备份文件列表: $old_files"

        if [ -n "$old_files" ]; then
          for old_file in $old_files; do
            delete_url="${target%/}/${old_file}"
            curl -u "$username:$password" -X DELETE "$delete_url" >"$TEMP_LOG" 2>&1
            if [ $? -eq 0 ]; then
              echo -e "\033[32m✔ 删除旧文件: $delete_url\033[0m"
              log "WebDAV 旧备份删除成功: $delete_url"
            else
              echo -e "\033[31m✗ 删除旧文件失败: $delete_url\033[0m"
              echo "服务器响应："
              cat "$TEMP_LOG"
              log "WebDAV 旧备份删除失败: $(cat "$TEMP_LOG")"
            fi
          done
        else
          echo -e "\033[32m✔ 无旧备份需要清理\033[0m"
          log "WebDAV 无旧备份需要清理"
        fi
      else
        echo -e "\033[31m✗ 无法获取 WebDAV 文件列表\033[0m"
        echo "服务器响应："
        cat "$TEMP_LOG"
        log "WebDAV 获取文件列表失败: $(cat "$TEMP_LOG")"
      fi
      rm -f "$TEMP_LOG"
      ;;
    sftp)
      echo -e "\033[36m正在清理 SFTP 旧备份...\033[0m"
      echo "ls" | sftp -b - "$username@${target#sftp://}" >"$TEMP_LOG" 2>&1
      if [ $? -eq 0 ]; then
        old_files=$(grep -v "$filename" "$TEMP_LOG" | grep -E '\.(tar\.gz|sql\.gz)$')
        for old_file in $old_files; do
          echo "rm $old_file" | sftp -b - "$username@${target#sftp://}" >/dev/null 2>&1
          if [ $? -eq 0 ]; then
            echo -e "\033[32m✔ 删除旧文件: $old_file\033[0m"
            log "SFTP 旧备份删除成功: $old_file"
          else
            echo -e "\033[33m⚠ 删除旧文件失败: $old_file\033[0m"
            log "SFTP 旧备份删除失败: $old_file"
          fi
        done
      else
        echo -e "\033[33m⚠ 无法获取 SFTP 文件列表，跳过清理\033[0m"
        log "SFTP 获取文件列表失败: $(cat "$TEMP_LOG")"
      fi
      rm -f "$TEMP_LOG"
      ;;
    ftp|rsync)
      echo -e "\033[33m⚠ $protocol 暂不支持自动清理旧备份，请手动管理远端文件\033[0m"
      log "$protocol 不支持自动清理旧备份"
      ;;
    local)
      echo -e "\033[36m正在清理本地旧备份...\033[0m"
      find "$target" -type f \( -name "*.tar.gz" -o -name "*.sql.gz" \) -not -name "$filename" -exec rm -f {} \;
      if [ $? -eq 0 ]; then
        echo -e "\033[32m✔ 本地旧备份清理成功\033[0m"
        log "本地旧备份清理成功"
      else
        echo -e "\033[33m⚠ 本地旧备份清理失败\033[0m"
        log "本地旧备份清理失败"
      fi
      ;;
  esac

  # 上传新备份
  case $protocol in
    webdav)
      echo -e "\033[36m正在上传到 WebDAV: $url...\033[0m"
      curl -u "$username:$password" -T "$file" "$url" -v >"$TEMP_LOG" 2>&1
      curl_status=$?
      log "curl 上传返回码: $curl_status"
      if [ $curl_status -eq 0 ]; then
        curl -u "$username:$password" -I "$url" >"$TEMP_LOG" 2>&1
        if grep -q "HTTP/[0-9.]* 200" "$TEMP_LOG" || grep -q "HTTP/[0-9.]* 201" "$TEMP_LOG"; then
          echo -e "\033[32m✔ 上传成功: $url\033[0m"
          log "备份上传成功: $url"
          rm -f "$file"
          rm -f "$TEMP_LOG"
          return 0
        else
          echo -e "\033[31m✗ 上传失败：服务器未确认文件存在\033[0m"
          echo "服务器响应："
          cat "$TEMP_LOG"
          log "备份上传失败: 服务器未确认文件存在"
          rm -f "$TEMP_LOG"
          return 1
        fi
      else
        echo -e "\033[31m✗ 上传失败：\033[0m"
        cat "$TEMP_LOG"
        log "备份上传失败: $(cat "$TEMP_LOG")"
        rm -f "$TEMP_LOG"
        return 1
      fi
      ;;
    ftp)
      echo -e "\033[36m正在上传到 FTP: $url...\033[0m"
      ftp -n "${target#ftp://}" <<EOF
user $username $password
put $file $filename
bye
EOF
      ;;
    sftp)
      echo -e "\033[36m正在上传到 SFTP: $url...\033[0m"
      echo "put $file $filename" | sftp -b - -i "$password" "$username@${target#sftp://}" >/dev/null 2>&1
      ;;
    scp)
      echo -e "\033[36m正在上传到 SCP: $url...\033[0m"
      scp -i "$password" "$file" "$username@${target#scp://}:$filename" >/dev/null 2>&1
      ;;
    rsync)
      echo -e "\033[36m正在同步到 rsync: $url...\033[0m"
      rsync -e "ssh -i $password" "$file" "$username@${target#rsync://}:$filename" >/dev/null 2>&1
      ;;
    local)
      mkdir -p "$target"
      mv "$file" "$target/$filename"
      if [ $? -eq 0 ]; then
        echo -e "\033[32m✔ 本地备份成功: $target/$filename\033[0m"
        log "本地备份成功: $target/$filename"
        return 0
      else
        echo -e "\033[31m✗ 本地备份失败\033[0m"
        log "本地备份失败"
        return 1
      fi
      ;;
  esac

  if [ $? -eq 0 ]; then
    echo -e "\033[32m✔ 上传成功: $url\033[0m"
    log "备份上传成功: $url"
    rm -f "$file"
    return 0
  else
    echo -e "\033[31m✗ 上传失败，请检查配置\033[0m"
    log "备份上传失败: $url"
    return 1
  fi
}


# 安装数据库客户端 (简化版)
install_db_client() {
   local db_type=$1 pkg="" needed=false
   if [[ "$db_type" == "mysql" ]]; then pkg="mysql-client"; if ! command -v mysqldump >/dev/null; then needed=true; fi
   elif [[ "$db_type" == "postgres" ]]; then pkg="postgresql-client"; if ! command -v pg_dump >/dev/null || ! command -v psql >/dev/null; then needed=true; fi
   else echo "DB类型错误"; return 1; fi
   if $needed; then echo "需要 $pkg"; read -p "是否安装?(y/N):" install_cli; if [[ "$install_cli" == "y" || "$install_cli" == "Y" ]]; then apt-get update -qq && apt-get install -y "$pkg" || { echo "安装失败"; return 1; }; echo "$pkg 安装成功"; else echo "未安装客户端"; return 1; fi; fi
   return 0
}

# --- Full Backup Menu Helper Functions ---
ManualBackupData() {
  echo -e "\033[36m▶ 手动备份程序数据...\033[0m"; log "手动备份数据开始..."
  read -p "源路径: " source_path
  read -e -p "目标路径: " target_path
  read -p "目标用户(可选): " username
  local password=""
  if [ -n "$username" ]; then read -s -p "密码/密钥路径(可选): " password; echo; fi
  if [ ! -e "$source_path" ]; then echo "源路径无效"; log "错误:手动备份数据源无效 $source_path"; return 1; fi
  local timestamp source_basename backup_file tar_status
  timestamp=$(date '+%Y%m%d_%H%M%S'); source_basename=$(basename "$source_path"); backup_file="/tmp/backup_${source_basename}_$timestamp.tar.gz"
  echo "压缩 '$source_path' -> '$backup_file' ...";
  # Use -P to preserve absolute paths if needed, otherwise -C is safer
  # tar -czf "$backup_file" -P "$source_path" 2>"$TEMP_LOG" # Option 1: Absolute path
  tar -czf "$backup_file" -C "$(dirname "$source_path")" "$source_basename" 2>"$TEMP_LOG" # Option 2: Relative path (safer)
  tar_status=$?
  if [ $tar_status -eq 0 ] && [ -s "$backup_file" ]; then
    echo "压缩成功"; upload_backup "$backup_file" "$target_path" "$username" "$password"
    if [ $? -eq 0 ]; then echo "备份上传成功"; log "手动数据备份成功: $source_path -> $target_path"; return 0; # Success
    else echo "上传失败"; log "手动数据备份失败(上传): $source_path -> $target_path"; rm -f "$backup_file"; return 1; fi
  else
    echo "压缩失败(码:$tar_status)"; cat "$TEMP_LOG"; log "手动数据备份失败(压缩): $source_path Error: $(cat "$TEMP_LOG")"; rm -f "$backup_file"; return 1;
  fi; rm -f "$TEMP_LOG" # Clean up temp log
}

ManualBackupDB() {
  echo -e "\033[36m▶ 手动备份数据库...\033[0m"; log "手动备份数据库开始..."
  local db_type db_host db_port db_user db_pass target_path username password backup_failed=false
  if ! load_config; then
      echo "未加载配置,请手动输入"; read -p "类型(mysql/postgres): " db_type; read -p "主机(127.0.0.1): " db_host; db_host=${db_host:-127.0.0.1}; read -p "端口(默认): " db_port; [ -z "$db_port" ] && db_port=$([ "$db_type" = "mysql" ] && echo 3306 || echo 5432); read -p "用户: " db_user; read -s -p "密码: " db_pass; echo; read -e -p "目标路径: " target_path; read -p "目标用户(可选): " username; if [ -n "$username" ]; then read -s -p "目标密码/密钥(可选): " password; echo; fi;
  else echo "已加载配置"; db_type=$DB_TYPE; db_host=$DB_HOST; db_port=$DB_PORT; db_user=$DB_USER; db_pass=$DB_PASS; target_path=$TARGET_PATH; username=$TARGET_USER; password=$TARGET_PASS; fi
  if [[ "$db_type" != "mysql" && "$db_type" != "postgres" ]]; then echo "类型错误"; return 1; fi; install_db_client "$db_type" || return 1;
  echo "测试连接..."; local connection_ok=false; if [ "$db_type" = "mysql" ]; then echo "SHOW DATABASES;" | mysql -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" >"$TEMP_LOG" 2>&1; [ $? -eq 0 ] && connection_ok=true || cat "$TEMP_LOG" >&2; elif [ "$db_type" = "postgres" ]; then export PGPASSWORD="$db_pass"; echo "SELECT 1;" | psql -h "$db_host" -p "$db_port" -U "$db_user" -d "postgres" -t >"$TEMP_LOG" 2>&1; [ $? -eq 0 ] && grep -q "1" "$TEMP_LOG" && connection_ok=true || cat "$TEMP_LOG" >&2; unset PGPASSWORD; fi;
  if ! $connection_ok; then echo "连接失败"; log "DB连接失败"; rm -f "$TEMP_LOG"; return 1; fi; echo "连接成功"; rm -f "$TEMP_LOG";
  read -p "备份所有数据库?(y/n/a)[y]: " backup_scope; backup_scope=${backup_scope:-y}; local db_list="";
  if [[ "$backup_scope" == "y" ]]; then db_list="all"; elif [[ "$backup_scope" == "n" ]]; then read -p "输入DB名(空格分隔): " db_names; if [ -z "$db_names" ]; then echo "未输入"; return 1; fi; db_list="$db_names"; else return 0; fi;
  local timestamp; timestamp=$(date '+%Y%m%d_%H%M%S');
  if [ "$db_list" = "all" ]; then
     local backup_file="/tmp/all_dbs_${db_type}_$timestamp.sql.gz"; echo "备份所有..."; local dump_cmd dump_status
     if [ "$db_type" = "mysql" ]; then dump_cmd="mysqldump -h \"$db_host\" -P \"$db_port\" -u \"$db_user\" -p\"$db_pass\" --all-databases --routines --triggers --single-transaction"; elif [ "$db_type" = "postgres" ]; then export PGPASSWORD="$db_pass"; dump_cmd="pg_dumpall -h \"$db_host\" -p \"$db_port\" -U \"$db_user\""; fi;
     # Use eval carefully, ensure variables are reasonably safe or quoted if complex
     eval "$dump_cmd" 2>"$TEMP_LOG" | gzip > "$backup_file"; dump_status=${PIPESTATUS[0]}; if [ "$db_type" = "postgres" ]; then unset PGPASSWORD; fi;
     if [ $dump_status -eq 0 ] && [ -s "$backup_file" ]; then echo "备份成功"; upload_backup "$backup_file" "$target_path" "$username" "$password" || backup_failed=true;
     else echo "备份失败(码:$dump_status)"; cat "$TEMP_LOG" >&2; log "备份所有DB失败: $(cat "$TEMP_LOG")"; backup_failed=true; rm -f "$backup_file"; fi;
  else
     for db_name in $db_list; do
         local backup_file="/tmp/${db_name}_${db_type}_$timestamp.sql.gz"; echo "备份 $db_name..."; local dump_cmd dump_status
         if [ "$db_type" = "mysql" ]; then dump_cmd="mysqldump -h \"$db_host\" -P \"$db_port\" -u \"$db_user\" -p\"$db_pass\" --routines --triggers --single-transaction \"$db_name\""; elif [ "$db_type" = "postgres" ]; then export PGPASSWORD="$db_pass"; dump_cmd="pg_dump -h \"$db_host\" -p \"$db_port\" -U \"$db_user\" \"$db_name\""; fi;
         eval "$dump_cmd" 2>"$TEMP_LOG" | gzip > "$backup_file"; dump_status=${PIPESTATUS[0]}; if [ "$db_type" = "postgres" ]; then unset PGPASSWORD; fi;
         if [ $dump_status -eq 0 ] && [ -s "$backup_file" ]; then echo "$db_name 备份成功"; upload_backup "$backup_file" "$target_path" "$username" "$password" || backup_failed=true;
         else echo "$db_name 备份失败(码:$dump_status)"; cat "$TEMP_LOG" >&2; log "备份DB $db_name 失败: $(cat "$TEMP_LOG")"; backup_failed=true; rm -f "$backup_file"; fi;
     done
  fi; rm -f "$TEMP_LOG"; if ! $backup_failed; then echo "所有请求的备份完成"; log "手动DB备份完成"; return 0; else echo "部分备份失败"; return 1; fi
}
ManageBackupConfig() {
  echo "管理配置...";
  if [ -f "$CONFIG_FILE" ]; then echo "当前配置:"; cat "$CONFIG_FILE"; read -p "操作(e:编辑/c:重建/n:返回)[n]: " cfg_act; cfg_act=${cfg_act:-n}; if [ "$cfg_act" == "e" ]; then ${EDITOR:-nano} "$CONFIG_FILE"; elif [ "$cfg_act" == "c" ]; then create_config; fi;
  else read -p "未找到配置,是否创建(y/N):" create_cfg; if [[ "$create_cfg" == "y" || "$create_cfg" == "Y" ]]; then create_config; fi; fi
}
ManageBackupCron() {
  echo "管理计划...";
  echo "当前任务:"; if [ -f "$BACKUP_CRON" ]; then grep -vE '^[[:space:]]*#|^$' "$BACKUP_CRON" | nl; if ! grep -qE '[^[:space:]]' "$BACKUP_CRON"; then echo " (无)"; fi; else echo " (无)"; fi; echo ""; read -p "操作(a:添加/d:删除/e:编辑/n:返回)[n]: " cron_action; cron_action=${cron_action:-n}
  if [[ "$cron_action" == "a" ]]; then
      echo "添加任务..."; local backup_type backup_failed=false
      read -p "类型(1:数据/2:数据库): " backup_type;
      if [ "$backup_type" = "1" ]; then
          read -p "源路径: " source_path; read -e -p "目标路径: " target_path; read -p "目标用户(可选): " username; local password=""; if [ -n "$username" ]; then read -s -p "密码/密钥路径(可选): " password; echo; fi;
          if [ ! -e "$source_path" ]; then echo "源无效"; return 1; fi;
          local source_basename timestamp_format backup_filename temp_backup_file tar_cmd cron_cmd_base
          source_basename=$(basename "$source_path"); timestamp_format='$(date +\%Y\%m\%d_\%H\%M\%S)'; backup_filename="backup_${source_basename}_${timestamp_format}.tar.gz"; temp_backup_file="/tmp/$backup_filename";
          tar_cmd="tar -czf '$temp_backup_file' -C '$(dirname "$source_path")' '$source_basename'"; cron_cmd_base="$tar_cmd && ";
          add_cron_job "$temp_backup_file" "$target_path" "$username" "$password" "$cron_cmd_base" || backup_failed=true;
      elif [ "$backup_type" = "2" ]; then
          if ! load_config; then echo "需先创建配置"; return 1; fi; local db_type db_host db_port db_user db_pass target_path username password; db_type=$DB_TYPE; db_host=$DB_HOST; db_port=$DB_PORT; db_user=$DB_USER; db_pass=$DB_PASS; target_path=$TARGET_PATH; username=$TARGET_USER; password=$TARGET_PASS;
          install_db_client "$db_type" || return 1;
          read -p "备份所有?(y/n)[y]: " backup_scope_cron; backup_scope_cron=${backup_scope_cron:-y}; local db_list_cron="";
          if [[ "$backup_scope_cron" == "y" ]]; then db_list_cron="all";
          elif [[ "$backup_scope_cron" == "n" ]]; then read -p "输入DB名: " db_names_cron; if [ -z "$db_names_cron" ]; then echo "未输入"; return 1; fi; db_list_cron="$db_names_cron";
          else echo "无效选择"; return 1; fi;
          local timestamp_format='$(date +\%Y\%m\%d_\%H\%M\%S)'
          if [ "$db_list_cron" = "all" ]; then
              local backup_filename temp_backup_file dump_cmd cron_cmd_base
              backup_filename="all_dbs_${db_type}_${timestamp_format}.sql.gz"; temp_backup_file="/tmp/$backup_filename"; dump_cmd="";
              if [ "$db_type" = "mysql" ]; then dump_cmd="mysqldump -h '$db_host' -P '$db_port' -u '$db_user' -p'$db_pass' --all-databases --routines --triggers --single-transaction"; elif [ "$db_type" = "postgres" ]; then dump_cmd="PGPASSWORD='$db_pass' pg_dumpall -h '$db_host' -p '$db_port' -U '$db_user'"; fi;
              cron_cmd_base="$dump_cmd | gzip > '$temp_backup_file' && ";
              add_cron_job "$temp_backup_file" "$target_path" "$username" "$password" "$cron_cmd_base" || backup_failed=true;
          else
              for db_name in $db_list_cron; do
                  local backup_filename temp_backup_file dump_cmd cron_cmd_partial
                  backup_filename="${db_name}_${db_type}_${timestamp_format}.sql.gz"; temp_backup_file="/tmp/$backup_filename"; dump_cmd="";
                  if [ "$db_type" = "mysql" ]; then dump_cmd="mysqldump -h '$db_host' -P '$db_port' -u '$db_user' -p'$db_pass' --routines --triggers --single-transaction '$db_name'"; elif [ "$db_type" = "postgres" ]; then dump_cmd="PGPASSWORD='$db_pass' pg_dump -h '$db_host' -p '$db_port' -U '$db_user' '$db_name'"; fi;
                  cron_cmd_partial="$dump_cmd | gzip > '$temp_backup_file' && ";
                  add_cron_job "$temp_backup_file" "$target_path" "$username" "$password" "$cron_cmd_partial" || backup_failed=true;
              done
          fi
      else echo "类型错误"; return 1; fi;
      if ! $backup_failed; then echo "Cron任务添加/更新完成"; else echo "部分Cron任务添加失败"; fi;
  elif [[ "$cron_action" == "d" ]]; then read -p "确定删除所有备份任务($BACKUP_CRON)?(y/N): " confirm_delete; if [[ "$confirm_delete" == "y" || "$confirm_delete" == "Y" ]]; then rm -v "$BACKUP_CRON" && echo "已删除" || echo "删除失败"; log "备份任务文件已删除"; fi
  elif [[ "$cron_action" == "e" ]]; then [ ! -f "$BACKUP_CRON" ] && touch "$BACKUP_CRON"; ${EDITOR:-nano} "$BACKUP_CRON"; chmod 644 "$BACKUP_CRON"; fi
}
# --- End Backup Menu Helper Functions ---

# 备份菜单
backup_menu() {
   while true; do clear_cmd; echo -e "\033[34m💾 备份工具 ▍\033[0m"; echo -e "\033[36m"; echo " 1) 手动备份程序数据"; echo " 2) 手动备份数据库"; echo " 3) 创建/管理备份配置文件 ($CONFIG_FILE)"; echo " 4) 设置/查看备份计划任务"; echo " 5) 返回主菜单"; echo -e "\033[0m"; read -p "请输入选项 (1-5): " choice; case $choice in 1) ManualBackupData;; 2) ManualBackupDB;; 3) ManageBackupConfig;; 4) ManageBackupCron;; 5) return;; *) echo "无效选项";; esac; read -p "按回车继续..."; done
}

# 添加 Cron 任务 (含密码警告)
add_cron_job() {
   local temp_backup_file="$1" target_path="$2" username="$3" password="$4" cron_cmd_base="$5"
   local backup_filename protocol host path_part target_clean url minute hour cron_day final_cron_cmd
   backup_filename=$(basename "$temp_backup_file")
   if [[ -n "$password" ]]; then echo -e "\033[31m警告：密码/密钥将明文写入Cron文件($BACKUP_CRON)，存在安全风险！\033[0m"; read -p "确认继续?(y/N): " confirm_pass; if [[ "$confirm_pass" != "y" && "$confirm_pass" != "Y" ]]; then echo "取消"; return 1; fi; fi
   target_clean="${target_path%/}"; protocol="local"; url="$target_clean/$backup_filename"; upload_cmd="mkdir -p '$target_clean' && mv '$temp_backup_file' '$url'"
   if [[ "$target_path" =~ ^https?:// ]]; then protocol="webdav"; url="$target_clean/$backup_filename"; upload_cmd="curl -sSf -u '$username:$password' -T '$temp_backup_file' '$url'";
   elif [[ "$target_path" =~ ^ftps?:// ]]; then protocol="ftp"; host=$(echo "$target_path" | sed -E 's|^ftps?://([^/]+).*|\1|'); path_part=$(echo "$target_path" | sed -E 's|^ftps?://[^/]+(/.*)?|\1|'); if command -v lftp > /dev/null; then upload_cmd="lftp -c \"set ftp:ssl-allow no; open -u '$username','$password' '$host'; cd '$path_part'; put '$temp_backup_file' -o '$backup_filename'; bye\""; else upload_cmd="echo -e 'user $username $password\\nbinary\\ncd $path_part\\nput $temp_backup_file $backup_filename\\nquit' | ftp -n '$host'"; fi;
   elif [[ "$target_path" =~ ^sftp:// ]]; then protocol="sftp"; host=$(echo "$target_path" | sed -E 's|^sftp://([^/]+).*|\1|'); path_part=$(echo "$target_path" | sed -E 's|^sftp://[^/]+(/.*)?|\1|'); st="$username@$host"; pc="put '$temp_backup_file' '$path_part/$backup_filename'"; qc="quit"; if [[ -f "$password" ]]; then upload_cmd="echo -e '$pc\\n$qc' | sftp -i '$password' '$st'"; elif [[ -n "$password" ]] && command -v sshpass > /dev/null; then upload_cmd="echo -e '$pc\\n$qc' | sshpass -p '$password' sftp '$st'"; elif [[ -n "$password" ]]; then echo "sshpass needed"; return 1; else upload_cmd="echo -e '$pc\\n$qc' | sftp '$st'"; fi;
   elif [[ "$target_path" =~ ^scp:// ]]; then protocol="scp"; uph=$(echo "$target_path" | sed 's|^scp://||'); host=$(echo "$uph" | cut -d: -f1); path_part=$(echo "$uph" | cut -d: -f2); [ -z "$path_part" ] && path_part="."; st="$username@$host:'$path_part/$backup_filename'"; if [[ -f "$password" ]]; then upload_cmd="scp -i '$password' '$temp_backup_file' '$st'"; elif [[ -n "$password" ]] && command -v sshpass > /dev/null; then upload_cmd="sshpass -p '$password' scp '$temp_backup_file' '$st'"; elif [[ -n "$password" ]]; then echo "sshpass needed"; return 1; else upload_cmd="scp '$temp_backup_file' '$st'"; fi;
   elif [[ "$target_path" =~ ^rsync:// ]]; then protocol="rsync"; uph=$(echo "$target_path" | sed 's|^rsync://||'); host=$(echo "$uph" | cut -d: -f1); path_part=$(echo "$uph" | cut -d: -f2); [ -z "$path_part" ] && path_part="."; rt="$username@$host:'$path_part/$backup_filename'"; ro="-az"; sshc="ssh"; if [[ -f "$password" ]]; then sshc="ssh -i \'$password\'"; elif [[ -n "$password" ]] && command -v sshpass > /dev/null; then sshc="sshpass -p \'$password\' ssh"; elif [[ -n "$password" ]]; then echo "sshpass needed"; return 1; fi; upload_cmd="rsync $ro -e \"$sshc\" '$temp_backup_file' '$rt'";
   elif [[ ! "$target_path" =~ ^/ ]]; then echo "Cron不支持相对路径"; return 1; fi;
   echo "设置频率:"; echo " *每天, */2隔天, 0-6周几(0=日), 1,3,5周一三五"; read -p "Cron星期字段(*或1或1,5): " cron_day; read -p "运行小时(0-23): " hour; read -p "运行分钟(0-59)[0]: " minute; minute=${minute:-0};
   if ! [[ "$hour" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || ! [[ "$minute" =~ ^([0-9]|[1-5][0-9])$ ]]; then echo "时间无效"; return 1; fi; if [[ "$cron_day" != "*" && "$cron_day" != "*/2" && ! "$cron_day" =~ ^([0-6](,[0-6])*)$ ]]; then echo "星期无效"; return 1; fi;
   local rm_cmd="rm -f '$temp_backup_file'"; [[ "$protocol" == "rsync" ]] && rm_cmd="";
   final_cron_cmd="bash -c \"{ ( $cron_cmd_base $upload_cmd && $rm_cmd && echo \\\$(date '+%Y-%m-%d %H:%M:%S') - Cron SUCCESS: $backup_filename\\\ >> $LOG_FILE ) || echo \\\$(date '+%Y-%m-%d %H:%M:%S') - Cron FAILED: $backup_filename\\\ >> $LOG_FILE ; } 2>&1 | tee -a $LOG_FILE\"";
   echo "$minute $hour * * $cron_day root $final_cron_cmd" >> "$BACKUP_CRON"; if [ $? -ne 0 ]; then echo "写入 $BACKUP_CRON 失败"; return 1; fi; chmod 644 "$BACKUP_CRON"; echo "任务已添加到 $BACKUP_CRON"; log "添加备份Cron: $minute $hour * * $cron_day - $backup_filename"; return 0;
}

# --- Full Toolbox Helper Functions ---
InstallDocker(){
    echo -e "\033[36m▶ 检查并安装/升级 Docker...\033[0m"
    if ! command -v curl >/dev/null 2>&1; then echo -e "\033[31m✗ 需要 curl\033[0m"; return 1; fi
    local docker_installed=false current_version=""
    if command -v docker >/dev/null 2>&1; then
         current_version=$(docker --version 2>/dev/null | awk '{print $3}' | sed 's/,//')
         if [ -n "$current_version" ]; then echo "当前 Docker 版本: $current_version"; docker_installed=true;
         else echo -e "\033[33m警告:无法获取 Docker 版本号\033[0m"; fi
    else echo "未检测到 Docker。"; fi
    read -p "运行官方脚本安装/升级 Docker？(y/N): " install_docker
    if [[ "$install_docker" == "y" || "$install_docker" == "Y" ]]; then
        echo "运行 get.docker.com..."; curl -fsSL https://get.docker.com | sh
        if [ $? -eq 0 ]; then
            echo -e "\033[32m✔ Docker 安装/升级脚本执行成功。\033[0m"; log "Docker 安装/升级成功"
            if command -v systemctl > /dev/null; then
                echo "尝试启动 Docker 服务..."; systemctl enable docker > /dev/null 2>&1; systemctl start docker > /dev/null 2>&1
                if systemctl is-active --quiet docker; then echo -e "\033[32m✔ Docker 服务已启动。\033[0m"; else echo -e "\033[33m⚠ Docker 服务启动失败。\033[0m"; fi
            fi
        else echo -e "\033[31m✗ Docker 安装/升级脚本执行失败。\033[0m"; log "Docker 安装/升级失败"; return 1; fi
    else echo "跳过 Docker 安装/升级。"; fi
    return 0
}
SyncTime(){
    echo -e "\033[36m▶ 正在同步服务器时间 (使用 systemd-timesyncd)...\033[0m"
    if ! command -v timedatectl > /dev/null; then echo -e "\033[31m✗ 未找到 timedatectl。\033[0m"; log "时间同步失败:无timedatectl"; return 1; fi
    echo "检查 timesyncd 服务状态...";
    if ! dpkg -s systemd-timesyncd >/dev/null 2>&1 && command -v apt-get > /dev/null; then
         echo "未找到 systemd-timesyncd，尝试安装..."; apt-get update -qq && apt-get install -y systemd-timesyncd || { echo "安装失败"; log "安装timesyncd失败"; return 1; }
    fi
    echo "启用并重启 systemd-timesyncd 服务...";
    systemctl enable systemd-timesyncd > /dev/null 2>&1
    systemctl restart systemd-timesyncd
    sleep 2 # 等待服务
    if systemctl is-active --quiet systemd-timesyncd; then
        echo -e "\033[32m✔ systemd-timesyncd 服务运行中。\033[0m"; echo "设置系统时钟使用 NTP 同步..."; timedatectl set-ntp true
         if [ $? -eq 0 ]; then echo -e "\033[32m✔ NTP 同步已启用。\033[0m"; log "时间同步配置完成"; else echo -e "\033[31m✗ 启用 NTP 同步失败。\033[0m"; log "启用 NTP 同步失败"; fi;
         echo "当前时间状态："; timedatectl status;
    else echo -e "\033[31m✗ systemd-timesyncd 服务启动失败。\033[0m"; log "timesyncd启动失败"; return 1; fi
    return 0
}
# --- End Full Toolbox Helper Functions ---

# 工具箱 (美化, 恢复函数调用)
toolbox_menu() {
   while true; do
       clear_cmd
       # 使用与主菜单类似的 Logo 和颜色逻辑
       local colors=("\033[31m" "\033[38;5;208m" "\033[33m" "\033[32m" "\033[34m" "\033[35m")
       local num_colors=${#colors[@]}
       local color_index=0
       local logo_lines=(
"    ██████╗██████╗ ██╗███████╗████████╗███████╗ █████╗ ██╗    ██╗"
"  ██╔════╝██╔══██╗██║██╔════╝╚══██╔══╝██╔════╝██╔══██╗██║    ██║"
"  ██║     ██████╔╝██║███████╗   ██║   ███████╗███████║██║    ██║"
"  ██║     ██╔══██╗██║╚════██║   ██║   ╚════██║██╔══██║██║    ██║"
"  ╚██████╗██║  ██║██║███████║   ██║   ███████║██║  ██║╚██████╔╝"
"   ╚═════╝╚═╝  ╚═╝╚═╝╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝ ╚═════╝  "
       )
       for line in "${logo_lines[@]}"; do echo -e "${colors[$color_index]}$line\033[0m"; color_index=$(( (color_index + 1) % num_colors )); done
       echo -e "\033[36m v$CURRENT_VERSION - 工具箱\033[0m"

       echo -e "\033[36m"
       echo " 1) 📦 升级或安装最新 Docker"
       echo " 2) 🕒 同步服务器时间 (systemd-timesyncd)"
       echo " 3) 🚀 检查并开启 BBR + fq"
       echo " 4) 💾 备份工具 (手动备份/配置/计划)"
       echo " 5) ↩️ 返回主菜单"
       echo -e "\033[0m"
       read -p "请输入选项 (1-5): " choice
       case $choice in
         1) InstallDocker;;
         2) SyncTime;;
         3) enable_bbr;;
         4) backup_menu;; # 调用完整的 backup_menu 函数
         5) return;;
         *) echo "无效选项";;
       esac
       read -p "按回车继续..."
   done
}

# 主菜单
show_menu() {
  clear_cmd
  local colors=("\033[31m" "\033[38;5;208m" "\033[33m" "\033[32m" "\033[34m" "\033[35m")
  local num_colors=${#colors[@]}
  local color_index=0
  local logo_lines=(
"    ██████╗██████╗ ██╗███████╗████████╗███████╗ █████╗ ██╗    ██╗"
"  ██╔════╝██╔══██╗██║██╔════╝╚══██╔══╝██╔════╝██╔══██╗██║    ██║"
"  ██║     ██████╔╝██║███████╗   ██║   ███████╗███████║██║    ██║"
"  ██║     ██╔══██╗██║╚════██║   ██║   ╚════██║██╔══██║██║    ██║"
"  ╚██████╗██║  ██║██║███████║   ██║   ███████║██║  ██║╚██████╔╝"
"   ╚═════╝╚═╝  ╚═╝╚═╝╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝ ╚═════╝  "
  )
  for line in "${logo_lines[@]}"; do echo -e "${colors[$color_index]}$line\033[0m"; color_index=$(( (color_index + 1) % num_colors )); done
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

# --- Main Execution ---
# Root check
if [ "$(id -u)" -ne 0 ]; then echo -e "\033[31m✗ 请使用 root 权限运行\033[0m"; exit 1; fi
# Main dependency check
check_main_dependencies
# Setup logrotate for the main log file upon script start/update
setup_main_logrotate

# Main loop
while true; do
  show_menu
  read -p "请输入选项 (1-9): " choice
  case $choice in
    1) install_script ;;
    2) if [ -f "$LOG_FILE" ]; then echo "监控日志 (Ctrl+C 退出)"; tail -f "$LOG_FILE"; else echo "日志不存在"; fi ;;
    3) view_status ;;
    4) if [ -x "$SCRIPT_PATH" ]; then echo "执行 $SCRIPT_PATH ..."; "$SCRIPT_PATH"; echo "执行完成。"; else echo "脚本未安装"; fi ;;
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