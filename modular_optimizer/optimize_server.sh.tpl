#!/bin/bash
# Generated by cristsau_modular_optimizer v__CURRENT_VERSION__ on $(date)

# --- Robustness ---
set -uo pipefail

# --- Basic Setup ---
if [ "$(id -u)" -ne 0 ]; then echo "错误：请以 root 权限运行"; exit 1; fi
LOG_FILE="__LOG_FILE__" # Placeholder replaced by install_script
OPTIMIZE_CONFIG_FILE="/etc/optimize.conf"
UPDATE_CACHE_FILE="/tmp/optimize_status_updates.cache" # Cache file for update checks

# --- Fallback Log ---
if ! touch "$LOG_FILE" 2>/dev/null; then LOG_FILE="/tmp/optimize_server.log.$(date +%Y%m%d)"; echo "警告：无法写入 \$LOG_FILE，尝试 \$LOG_FILE" >&2; if ! touch "$LOG_FILE" 2>/dev/null; then echo "错误：无法写入日志文件。" >&2; exit 1; fi; fi

# --- Logging Function ---
log() { local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S'); echo "$timestamp - $1" | tee -a "$LOG_FILE"; }

# --- Load Configuration with Defaults ---
CLEAN_LOG_DAYS=15; CLEAN_OLD_KERNELS=true; CLEAN_DOCKER_LOGS=true; CLEAN_USER_CACHE=true; CLEAN_TMP=true
if [ -f "$OPTIMIZE_CONFIG_FILE" ]; then log "加载优化配置 $OPTIMIZE_CONFIG_FILE"; ( source "$OPTIMIZE_CONFIG_FILE" ) && source "$OPTIMIZE_CONFIG_FILE" || log "警告: 加载配置 $OPTIMIZE_CONFIG_FILE 出错"; [[ "$CLEAN_OLD_KERNELS" != "true" && "$CLEAN_OLD_KERNELS" != "false" ]] && CLEAN_OLD_KERNELS=true; [[ ! "$CLEAN_LOG_DAYS" =~ ^[0-9]+$ ]] && CLEAN_LOG_DAYS=15; [[ "$CLEAN_LOG_DAYS" -lt 1 ]] && CLEAN_LOG_DAYS=1; [[ "$CLEAN_DOCKER_LOGS" != "true" && "$CLEAN_DOCKER_LOGS" != "false" ]] && CLEAN_DOCKER_LOGS=true; [[ "$CLEAN_USER_CACHE" != "true" && "$CLEAN_USER_CACHE" != "false" ]] && CLEAN_USER_CACHE=true; [[ "$CLEAN_TMP" != "true" && "$CLEAN_TMP" != "false" ]] && CLEAN_TMP=true; else log "未找到优化配置 $OPTIMIZE_CONFIG_FILE"; fi
log "生效配置: LOG=$CLEAN_LOG_DAYS, KERNEL=$CLEAN_OLD_KERNELS, DOCKER=$CLEAN_DOCKER_LOGS, CACHE=$CLEAN_USER_CACHE, TMP=$CLEAN_TMP"

# --- Dependency Check ---
check_dependencies() { log "检查优化脚本依赖..."; local missing_deps=(); local deps=("logrotate" "apt-get" "uname" "dpkg" "rm" "find" "tee" "df" "sync" "date" "docker" "grep" "sed" "awk" "free" "lscpu" "nproc" "lsb_release" "stat" "du" "cut" "which" "head" "tail" "jq" "truncate" "mkdir" "cp" "mv" "chmod"); for tool in "${deps[@]}"; do if ! command -v "$tool" &> /dev/null; then if [[ "$tool" == "docker" && "$CLEAN_DOCKER_LOGS" != "true" ]]; then continue; elif [[ "$tool" == "jq" && "$CLEAN_DOCKER_LOGS" != "true" ]]; then continue; elif [[ "$tool" == "docker" ]]; then log "警告: Docker 未安装"; elif [[ "$tool" == "jq" ]]; then log "警告: jq 未安装"; else missing_deps+=("$tool"); fi; fi; done; if [ ${#missing_deps[@]} -gt 0 ]; then log "错误: 缺少核心依赖: ${missing_deps[*]}"; exit 1; else log "依赖检查通过。"; fi; }

# --- Function to Check Package Updates and Cache Result ---
check_package_updates() { log "检查待更新软件包..."; local count="N/A"; if command -v apt-get >/dev/null ; then if apt-get update -qq >/dev/null 2>&1; then count=$(apt-get -s upgrade | grep -oP '^\d+(?= upgraded)'); [[ ! "$count" =~ ^[0-9]+$ ]] && count=0; log "找到 $count 个待更新软件包"; echo "UPGRADABLE_COUNT=$count" > "$UPDATE_CACHE_FILE"; else log "apt-get update 失败"; echo "UPGRADABLE_COUNT=Error" > "$UPDATE_CACHE_FILE"; fi; else log "未找到 apt-get"; echo "UPGRADABLE_COUNT=N/A" > "$UPDATE_CACHE_FILE"; fi; chmod 644 "$UPDATE_CACHE_FILE" 2>/dev/null || true; }

# --- Optimization Functions ---
configure_script_logrotate() { 
    log "配置脚本日志轮转..."; 
    cat > /etc/logrotate.d/optimize_server <<EOL
$LOG_FILE {
    rotate 7
    daily
    missingok
    notifempty
    delaycompress
    compress
    copytruncate
}
EOL
    log "脚本日志轮转配置完成。"; 
}
show_disk_usage() { log "当前磁盘使用情况："; df -h | tee -a "$LOG_FILE"; }
configure_logrotate() { 
    log "配置系统日志轮转..."; 
    cat > /etc/logrotate.d/rsyslog <<EOL
/var/log/syslog /var/log/mail.log /var/log/auth.log /var/log/kern.log /var/log/daemon.log /var/log/messages /var/log/user.log /var/log/debug /var/log/dpkg.log /var/log/apt/*.log {
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
    log "系统日志轮转配置完成。"; 
}
clean_old_syslogs() { log "清理超过 $CLEAN_LOG_DAYS 天的旧系统日志..."; find /var/log -type f '(' -name "*.log.[0-9]" -o -name "*.log.*.gz" -o -name "*.[0-9].gz" -o -name "*.[1-9]" ')' -mtime "+$((CLEAN_LOG_DAYS - 1))" -print -delete >> "$LOG_FILE" 2>&1; log "旧系统日志清理完成。"; }
configure_docker_logging() { if [[ "$CLEAN_DOCKER_LOGS" != "true" ]]; then log "跳过 Docker 日志轮转设置"; return 0; fi; if ! command -v docker &>/dev/null; then log "警告：Docker命令未找到"; return 0; fi; if ! docker info &>/dev/null; then log "警告：Docker服务未运行"; return 0; fi; log "配置Docker日志轮转..."; local DAEMON_JSON="/etc/docker/daemon.json"; local DAEMON_JSON_BACKUP="/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"; local default_json_content='{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }'; local docker_config_dir="/etc/docker"; if ! mkdir -p "$docker_config_dir"; then log "错误：无法创建目录 $docker_config_dir"; return 1; fi; if ! command -v jq &>/dev/null; then log "警告: jq未安装, 覆盖创建"; if [ -f "$DAEMON_JSON" ]; then cp "$DAEMON_JSON" "$DAEMON_JSON_BACKUP" && log "已备份"; fi; printf '%s\n' "$default_json_content" > "$DAEMON_JSON" || { log "写入失败"; return 1; }; chmod 644 "$DAEMON_JSON" || log "警告: 设置权限失败"; else if [ -f "$DAEMON_JSON" ]; then if jq -e . "$DAEMON_JSON" > /dev/null 2>&1; then log "合并配置"; cp "$DAEMON_JSON" "$DAEMON_JSON_BACKUP" && log "已备份"; if jq --argjson defaults "$default_json_content" '. + $defaults' "$DAEMON_JSON" > "$DAEMON_JSON.tmp"; then if mv "$DAEMON_JSON.tmp" "$DAEMON_JSON"; then log "配置合并成功"; chmod 644 "$DAEMON_JSON" || log "警告: 设置权限失败"; else log "错误: 移动合并文件失败"; cp "$DAEMON_JSON_BACKUP" "$DAEMON_JSON"; rm -f "$DAEMON_JSON.tmp"; return 1; fi; else log "错误: jq 合并失败"; cp "$DAEMON_JSON_BACKUP" "$DAEMON_JSON"; rm -f "$DAEMON_JSON.tmp" 2>/dev/null; return 1; fi; else log "警告:无效JSON,覆盖创建"; cp "$DAEMON_JSON" "$DAEMON_JSON_BACKUP" && log "已备份"; printf '%s\n' "$default_json_content" > "$DAEMON_JSON" || { log "写入失败"; return 1; }; chmod 644 "$DAEMON_JSON" || log "警告: 设置权限失败"; fi; else log "创建配置文件"; printf '%s\n' "$default_json_content" > "$DAEMON_JSON" || { log "写入失败"; return 1; }; chmod 644 "$DAEMON_JSON" || log "警告: 设置权限失败"; fi; fi; log "Docker日志配置完成,请重启Docker生效。"; return 0; }
clean_docker_logs() { if [[ "$CLEAN_DOCKER_LOGS" != "true" ]]; then log "跳过 Docker 容器日志清理"; return 0; fi; if ! command -v docker &>/dev/null; then log "警告：Docker命令未找到"; return 0; fi; if ! docker info >/dev/null 2>&1; then log "警告：Docker服务未运行"; return 0; fi; log "清理Docker容器日志..."; local containers="" container log_path cname exit_code=0; containers=$(docker ps -a -q 2>/dev/null); if [ $? -ne 0 ]; then log "错误: 'docker ps -a -q' 执行失败"; return 1; fi; if [ -z "$containers" ]; then log "未发现 Docker 容器。"; return 0; fi; echo "$containers" | while IFS= read -r container; do local inspect_output=""; inspect_output=$(docker inspect --format='{{.LogPath}} {{.Name}}' "$container" 2>/dev/null); if [ $? -ne 0 ]; then log "警告: 无法 inspect 容器 $container"; continue; fi; read -r log_path cname <<<"$inspect_output"; cname=${cname#/} ; if [ -n "$log_path" ] && [ -f "$log_path" ]; then log "清理容器($cname / ${container:0:12})日志..."; if truncate -s 0 "$log_path"; then log "容器 ($cname) 日志清理成功。"; else log "错误: 清理容器 ($cname) 日志失败"; exit_code=1; fi; else log "警告：未找到容器($cname / ${container:0:12})的日志文件或路径无效($log_path)。"; fi; done; log "Docker容器日志清理完成。"; return $exit_code; }
clean_apt_cache() { log "清理APT缓存..."; apt-get clean -y >> "$LOG_FILE" 2>&1; log "APT缓存清理完成。"; }
clean_old_kernels() { if [[ "$CLEAN_OLD_KERNELS" != "true" ]]; then log "跳过旧内核清理"; return 0; fi; log "清理旧内核..."; local current_kernel kernels_to_remove pkg; current_kernel=$(uname -r); kernels_to_remove=$(dpkg --list | grep -E '^ii +linux-(image|headers)-[0-9]' | grep -v "$current_kernel" | awk '{print $2}'); if [ -n "$kernels_to_remove" ]; then log "将移除:"; echo "$kernels_to_remove" | while IFS= read -r pkg; do log "  - $pkg"; done; log "执行 apt-get purge..."; if apt-get purge -y $kernels_to_remove >> "$LOG_FILE" 2>&1; then log "移除成功,清理残留..."; if apt-get autoremove -y >> "$LOG_FILE" 2>&1; then log "残留清理完成。"; else log "警告: autoremove 失败。"; fi; else log "错误：移除失败。"; fi; else log "无旧内核可清理。"; fi; log "旧内核清理任务结束。"; return 0; }
clean_tmp_files() { if [[ "$CLEAN_TMP" != "true" ]]; then log "跳过 /tmp 清理"; return 0; fi; log "清理/tmp目录..."; if [ -d /tmp ]; then find /tmp -mindepth 1 -maxdepth 1 ! -name "optimize_temp.log" -exec rm -rf {} \; 2>> "$LOG_FILE"; log "临时文件清理完成。"; else log "警告：/tmp不存在"; fi; return 0; }
clean_user_cache() { if [[ "$CLEAN_USER_CACHE" != "true" ]]; then log "跳过用户缓存清理"; return 0; fi; log "清理用户缓存..."; find /home/*/.cache -maxdepth 1 -mindepth 1 '(' -type d -exec rm -rf {} + -o -type f -delete ')'; if [ -d /root/.cache ]; then find /root/.cache -maxdepth 1 -mindepth 1 '(' -type d -exec rm -rf {} + -o -type f -delete ')'; log "清理root缓存完成"; fi; log "用户缓存清理完成。"; return 0; }

# --- Main Execution Flow ---
main() {
    log "=== 优化任务开始 v1.3 ===" # Updated version
    check_dependencies
    check_package_updates # Check updates at start
    show_disk_usage
    configure_script_logrotate
    configure_logrotate
    clean_old_syslogs
    if [[ "$CLEAN_DOCKER_LOGS" == "true" ]]; then configure_docker_logging; clean_docker_logs; fi
    clean_apt_cache
    if [[ "$CLEAN_OLD_KERNELS" == "true" ]]; then clean_old_kernels; fi
    if [[ "$CLEAN_TMP" == "true" ]]; then clean_tmp_files; fi
    if [[ "$CLEAN_USER_CACHE" == "true" ]]; then clean_user_cache; fi
    show_disk_usage
    log "=== 优化任务结束 ==="
}
main