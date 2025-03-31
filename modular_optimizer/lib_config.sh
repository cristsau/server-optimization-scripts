#!/bin/bash
# lib_config.sh - Configuration file handling

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
# Assume CONFIG_FILE, OPTIMIZE_CONFIG_FILE, LOG_FILE, SCRIPT_DIR are exported from main
# shellcheck source=./lib_utils.sh
source "$SCRIPT_DIR/lib_utils.sh" # For log, validate_numeric

# --- Backup Config Functions (Use CONFIG_FILE variable) ---
load_config() {
  DB_TYPE=""; DB_HOST=""; DB_PORT=""; DB_USER=""; DB_PASS=""; TARGET_PATH=""; TARGET_USER=""; TARGET_PASS=""; LOCAL_RETENTION_DAYS=1; REMOTE_RETENTION_DAYS=1;
  if [ -f "$CONFIG_FILE" ]; then
    ( source "$CONFIG_FILE" >/dev/null 2>&1 );
    if [ $? -eq 0 ]; then
        source "$CONFIG_FILE"; validate_numeric "${LOCAL_RETENTION_DAYS:-1}" "本地备份保留天数" || LOCAL_RETENTION_DAYS=1; validate_numeric "${REMOTE_RETENTION_DAYS:-1}" "远端备份保留天数" || REMOTE_RETENTION_DAYS=1; [[ "$LOCAL_RETENTION_DAYS" -lt 0 ]] && LOCAL_RETENTION_DAYS=0; [[ "$REMOTE_RETENTION_DAYS" -lt 0 ]] && REMOTE_RETENTION_DAYS=0;
        export DB_TYPE DB_HOST DB_PORT DB_USER DB_PASS TARGET_PATH TARGET_USER TARGET_PASS LOCAL_RETENTION_DAYS REMOTE_RETENTION_DAYS;
        log "加载备份配置: $CONFIG_FILE (本地保留: $LOCAL_RETENTION_DAYS 天, 远端保留: $REMOTE_RETENTION_DAYS 天)"; return 0;
    else log "错误:加载无效备份配置 $CONFIG_FILE"; echo -e "\033[31m✗ 加载备份配置失败\033[0m"; return 1; fi
  else log "未找到备份配置文件 $CONFIG_FILE"; export LOCAL_RETENTION_DAYS REMOTE_RETENTION_DAYS; return 1; fi
}

create_config() {
   log "创建/更新备份配置文件: $CONFIG_FILE"; echo -e "\033[36m▶ 创建/更新备份配置文件 ($CONFIG_FILE)...\033[0m";
   if [ -f "$CONFIG_FILE" ]; then read -p "配置已存在,覆盖?(y/N): " ovw; if [[ "$ovw" != "y" && "$ovw" != "Y" ]]; then echo "取消创建"; return 1; fi; fi
   local DB_TYPE DB_HOST DB_PORT DB_USER DB_PASS TARGET_PATH TARGET_USER TARGET_PASS LOCAL_RETENTION_DAYS REMOTE_RETENTION_DAYS default_port
   read -p "数据库类型 (mysql/postgres): " DB_TYPE; case "$DB_TYPE" in mysql) default_port=3306;; postgres) default_port=5432;; *) echo "类型错误"; return 1;; esac;
   read -p "数据库主机[127.0.0.1]: " DB_HOST; DB_HOST=${DB_HOST:-127.0.0.1}; read -p "数据库端口[默认 $default_port]: " DB_PORT; DB_PORT=${DB_PORT:-$default_port}; validate_numeric "$DB_PORT" "端口" || return 1;
   read -p "数据库用户: " DB_USER; read -s -p "数据库密码: " DB_PASS; echo; read -e -p "备份目标路径: " TARGET_PATH; read -p "目标用户(可选): " TARGET_USER; read -s -p "目标密码/密钥(可选): " TARGET_PASS; echo;
   read -p "本地备份保留天数 (0为不删除) [默认 1]: " LOCAL_RETENTION_DAYS; LOCAL_RETENTION_DAYS=${LOCAL_RETENTION_DAYS:-1}; validate_numeric "$LOCAL_RETENTION_DAYS" "本地保留天数" || return 1;
   read -p "远端备份保留天数 (0为不删除, 支持WebDAV/SFTP/FTP(lftp)) [默认 1]: " REMOTE_RETENTION_DAYS; REMOTE_RETENTION_DAYS=${REMOTE_RETENTION_DAYS:-1}; validate_numeric "$REMOTE_RETENTION_DAYS" "远端保留天数" || return 1;
   [[ "$LOCAL_RETENTION_DAYS" -lt 0 ]] && LOCAL_RETENTION_DAYS=0; [[ "$REMOTE_RETENTION_DAYS" -lt 0 ]] && REMOTE_RETENTION_DAYS=0;
   if [[ -z "$DB_TYPE" || -z "$DB_HOST" || -z "$DB_PORT" || -z "$DB_USER" || -z "$TARGET_PATH" ]]; then echo "必填项不能为空"; return 1; fi; if [[ -n "$TARGET_USER" && -z "$TARGET_PASS" ]]; then echo -e "\033[33m警告:指定用户但无密码/密钥\033[0m"; fi
   cat > "$CONFIG_FILE" <<EOF
# Backup Configuration File (Generated: $(date))
DB_TYPE="$DB_TYPE"
DB_HOST="$DB_HOST"
DB_PORT="$DB_PORT"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
TARGET_PATH="$TARGET_PATH"
TARGET_USER="$TARGET_USER"
TARGET_PASS="$TARGET_PASS"
LOCAL_RETENTION_DAYS="$LOCAL_RETENTION_DAYS"
REMOTE_RETENTION_DAYS="$REMOTE_RETENTION_DAYS"
EOF
   if [ $? -eq 0 ]; then chmod 600 "$CONFIG_FILE"; echo "配置创建/更新成功"; log "备份配置创建/更新成功"; return 0; else echo "写入配置失败"; log "写入备份配置失败"; return 1; fi
}

# --- Optimize Config Functions ---
load_optimize_config() {
    CLEAN_LOG_DAYS=15; CLEAN_OLD_KERNELS=true; CLEAN_DOCKER_LOGS=true; CLEAN_USER_CACHE=true; CLEAN_TMP=true
    if [ -f "$OPTIMIZE_CONFIG_FILE" ]; then log "加载优化配置: $OPTIMIZE_CONFIG_FILE"; source "$OPTIMIZE_CONFIG_FILE" || log "警告: 加载优化配置 $OPTIMIZE_CONFIG_FILE 时出错"; [[ "$CLEAN_OLD_KERNELS" != "true" && "$CLEAN_OLD_KERNELS" != "false" ]] && CLEAN_OLD_KERNELS=true; [[ ! "$CLEAN_LOG_DAYS" =~ ^[0-9]+$ ]] && CLEAN_LOG_DAYS=15; [[ "$CLEAN_LOG_DAYS" -lt 1 ]] && CLEAN_LOG_DAYS=1; [[ "$CLEAN_DOCKER_LOGS" != "true" && "$CLEAN_DOCKER_LOGS" != "false" ]] && CLEAN_DOCKER_LOGS=true; [[ "$CLEAN_USER_CACHE" != "true" && "$CLEAN_USER_CACHE" != "false" ]] && CLEAN_USER_CACHE=true; [[ "$CLEAN_TMP" != "true" && "$CLEAN_TMP" != "false" ]] && CLEAN_TMP=true;
    else log "优化配置文件 $OPTIMIZE_CONFIG_FILE 未找到, 使用默认值."; fi
    export CLEAN_LOG_DAYS CLEAN_OLD_KERNELS CLEAN_DOCKER_LOGS CLEAN_USER_CACHE CLEAN_TMP
}

create_optimize_config() {
    log "检查/创建优化配置文件: $OPTIMIZE_CONFIG_FILE"; if [ -f "$OPTIMIZE_CONFIG_FILE" ]; then log "优化配置文件已存在"; return 0; fi; echo -e "\033[36m▶ 创建默认优化配置文件 ($OPTIMIZE_CONFIG_FILE)...\033[0m";
    cat > "$OPTIMIZE_CONFIG_FILE" <<EOF
# Server Optimization Configuration (Generated: $(date))
CLEAN_LOG_DAYS=15
CLEAN_OLD_KERNELS=true
CLEAN_DOCKER_LOGS=true
CLEAN_USER_CACHE=true
CLEAN_TMP=true
EOF
    if [ $? -eq 0 ]; then chmod 644 "$OPTIMIZE_CONFIG_FILE"; echo "默认优化配置文件创建成功。"; log "默认优化配置创建成功"; return 0; else echo "写入优化配置失败。"; log "写入优化配置失败"; return 1; fi
}