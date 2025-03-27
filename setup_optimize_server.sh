#!/bin/bash
# 脚本名称：setup_optimize_server.sh
# 作者：cristsau
# 版本：5.0
# 功能：服务器优化管理工具

if [ "$(id -u)" -ne 0 ]; then
  echo -e "\033[31m✗ 请使用 root 权限运行此脚本\033[0m"
  exit 1
fi

SCRIPT_NAME="optimize_server.sh"
SCRIPT_PATH="/usr/local/bin/$SCRIPT_NAME"
LOG_FILE="/var/log/optimize_server.log"
TEMP_LOG="/tmp/optimize_temp.log"
CURRENT_VERSION="3.9"
BACKUP_CRON="/etc/cron.d/backup_cron"
CONFIG_FILE="/etc/backup.conf"

log() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "$timestamp - $1" | tee -a "$LOG_FILE"
  sync
  if [ $? -ne 0 ]; then
    echo "错误：无法写入日志到 $LOG_FILE，请检查权限或磁盘空间" >&2
    exit 1
  fi
}

convert_weekday() {
  case $1 in
    0) echo "日" ;;
    1) echo "一" ;;
    2) echo "二" ;;
    3) echo "三" ;;
    4) echo "四" ;;
    5) echo "五" ;;
    6) echo "六" ;;
    *) echo "未知" ;;
  esac
}

manage_cron() {
  crontab -l | grep -v "$SCRIPT_PATH" | crontab -
  if [ $# -eq 2 ]; then
    cron_min="0"
    cron_hr="$1"
    cron_day="$2"
    (crontab -l 2>/dev/null; echo "$cron_min $cron_hr * * $cron_day $SCRIPT_PATH") | crontab -
    log "已设置优化任务：每周 $cron_day 的 $cron_hr:00"
  fi
}

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    log "已加载配置文件: $CONFIG_FILE"
    return 0
  else
    echo -e "\033[33m警告：未找到配置文件 $CONFIG_FILE\033[0m"
    return 1
  fi
}

create_config() {
  echo -e "\033[36m▶ 创建备份配置文件...\033[0m"
  cat <<EOF > "$CONFIG_FILE"
# 数据库配置
DB_TYPE=postgres
DB_HOST=localhost
DB_PORT=5432
DB_USER=postgres
DB_PASS=

# 备份目标配置
TARGET_PATH=https://nas.cvv.gr/dav/CrisTsau/local/backup/lobechat/postgres
TARGET_USER=cristsau
TARGET_PASS=
EOF
  chmod 600 "$CONFIG_FILE"
  echo -e "\033[32m✔ 配置文件已创建: $CONFIG_FILE\033[0m"
  echo "请编辑 $CONFIG_FILE 并填入正确的密码"
  log "配置文件创建成功: $CONFIG_FILE"
}

install_script() {
  echo -e "\033[36m▶ 开始安装优化脚本...\033[0m"
  export INSTALL_MODE=1
  
  while true; do
    read -p "请输入每周运行的天数 (0-6 0=周日): " day
    read -p "请输入运行时间 (0-23): " hour
    if [[ $day =~ ^[0-6]$ ]] && [[ $hour =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
      break
    else
      echo -e "\033[31m✗ 无效输入，请重新输入\033[0m"
    fi
  done

  touch "$LOG_FILE"
  chmod 644 "$LOG_FILE"
  log "脚本安装开始"

  cat <<EOF > "$SCRIPT_PATH"
#!/bin/bash
if [ "\$(id -u)" -ne 0 ]; then
  echo "请以 root 权限运行此脚本"
  exit 1
fi
LOG_FILE="$LOG_FILE"
if [ ! -w /var/log ]; then
  LOG_FILE="/tmp/optimize_server.log"
  echo "警告：/var/log 不可写，日志将保存到 \$LOG_FILE" >&2
fi
log() {
  local timestamp=\$(date '+%Y-%m-%d %H:%M:%S')
  echo "\$timestamp - \$1" | tee -a "\$LOG_FILE"
  sync
  if [ \$? -ne 0 ]; then
    echo "错误：无法写入日志到 \$LOG_FILE，请检查权限或磁盘空间" >&2
    exit 1
  fi
}
configure_script_logrotate() {
  log "配置脚本日志轮转..."
  cat <<EOL > /etc/logrotate.d/optimize_server
\$LOG_FILE {
    rotate 7
    daily
    missingok
    notifempty
    delaycompress
    compress
}
EOL
  log "脚本日志轮转配置完成。"
}
check_dependencies() {
  log "检查必要的工具和服务..."
  for tool in logrotate apt-get uname dpkg rm; do
    if ! command -v "\$tool" &> /dev/null; then
      log "错误: \$tool 未找到，请安装该工具。"
      exit 1
    fi
  done
  log "所有必要工具和服务已找到。"
}
show_disk_usage() {
  log "当前磁盘使用情况："
  df -h | tee -a "\$LOG_FILE"
  sync
}
configure_logrotate() {
  log "配置 logrotate..."
  cat <<EOL > /etc/logrotate.d/rsyslog
/var/log/syslog
{
    rotate 3
    daily
    missingok
    notifempty
    delaycompress
    compress
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOL
  log "logrotate 配置完成。"
}
clean_old_syslogs() {
  log "清理超过15天的旧系统日志..."
  find /var/log -type f -name "*.log" -mtime +15 -exec rm {} \; 2>> "\$LOG_FILE"
  log "旧系统日志清理完成。"
}
configure_docker_logging() {
  if ! docker info &> /dev/null; then
    log "警告：Docker 未安装，跳过 Docker 日志轮转配置。"
    return
  fi
  log "配置 Docker 日志轮转..."
  if [ -f /etc/docker/daemon.json ]; then
    log "备份现有 /etc/docker/daemon.json 文件..."
    cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
  fi
  cat <<EOL > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOL
  log "Docker 日志轮转配置完成，请手动重启 Docker 服务以应用更改。"
}
clean_docker_logs() {
  if ! docker info &> /dev/null; then
    log "警告：Docker 未安装，跳过 Docker 容器日志清理。"
    return
  fi
  log "清理所有 Docker 容器日志..."
  for container in \$(docker ps -a --format '{{.ID}}'); do
    log_path=\$(docker inspect --format='{{.LogPath}}' "\$container")
    if [ -n "\$log_path" ] && [ -f "\$log_path" ]; then
      log "清理容器 \$container 的日志..."
      echo "" > "\$log_path"
    fi
  done
  log "Docker 容器日志清理完成。"
}
clean_apt_cache() {
  log "清理 APT 缓存..."
  apt-get clean
  log "APT 缓存清理完成。"
}
clean_old_kernels() {
  log "清理旧内核版本..."
  current_kernel=\$(uname -r)
  kernels=\$(dpkg --list | grep linux-image | awk '{print \$2}' | grep -v "\$current_kernel")
  if [ -n "\$kernels" ]; then
    log "即将移除以下旧内核版本：\$kernels"
    apt-get remove --purge -y \$kernels
    apt-get autoremove -y
    log "旧内核版本清理完成。"
  else
    log "没有可清理的旧内核"
  fi
}
clean_tmp_files() {
  log "清理 /tmp 目录..."
  if [ -d /tmp ]; then
    find /tmp -mindepth 1 -maxdepth 1 \
      ! -name "optimize_temp.log" \
      ! -name "*.tmp" \
      -exec rm -rf {} \;
    log "临时文件清理完成。"
  else
    log "警告：/tmp 目录不存在，跳过清理。"
  fi
}
clean_user_cache() {
  log "清理用户缓存..."
  for user in \$(ls /home); do
    cache_dir="/home/\$user/.cache"
    if [ -d "\$cache_dir" ]; then
      rm -rf "\$cache_dir"/*
      log "清理 \$user 的缓存完成。"
    fi
  done
  if [ -d /root/.cache ]; then
    rm -rf /root/.cache/*
    log "清理 root 用户的缓存完成。"
  fi
  log "用户缓存清理完成。"
}
main() {
  log "=== 优化任务开始 ==="
  show_disk_usage
  check_dependencies
  configure_script_logrotate
  configure_logrotate
  clean_old_syslogs
  configure_docker_logging
  clean_docker_logs
  clean_apt_cache
  clean_old_kernels
  clean_tmp_files
  clean_user_cache
  show_disk_usage
  log "=== 优化任务结束 ==="
}
main
EOF

  chmod +x "$SCRIPT_PATH"
  manage_cron "$hour" "$day"
  
  echo -e "\033[36m▶ 正在执行初始化测试...\033[0m"
  if "$SCRIPT_PATH" && grep -q "=== 优化任务开始 ===" "$LOG_FILE" && grep -q "=== 优化任务结束 ===" "$LOG_FILE"; then
    echo -e "\033[32m✔ 脚本安装成功\033[0m"
    log "脚本安装验证成功"
  else
    echo -e "\033[31m✗ 脚本测试失败，请检查日志\033[0m"
    echo "当前日志内容：" >&2
    cat "$LOG_FILE" >&2
    exit 1
  fi
  unset INSTALL_MODE
}

view_status() {
  clear
  echo -e "\033[34m▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▌ 任务状态信息 ▍▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀\033[0m"
  
  if [ -z "$LOG_FILE" ]; then
    echo "错误：日志文件路径未定义"
    return 1
  fi

  echo -e "\n\033[36m▌ 脚本安装信息 ▍\033[0m"
  echo "当前脚本版本: $CURRENT_VERSION"
  echo "优化脚本路径: $SCRIPT_PATH"
  echo "日志文件路径: $LOG_FILE"
  echo "日志文件大小: $(du -h "$LOG_FILE" | cut -f1 2>/dev/null || echo '未知')"
  if [ -f "$SCRIPT_PATH" ]; then
    echo "安装状态: 已安装"
    install_time=$(stat -c %Y "$SCRIPT_PATH" 2>/dev/null)
    if [ -n "$install_time" ]; then
      echo "安装时间: $(date -d "@$install_time" '+%Y-%m-%d %H:%M:%S')"
    fi
  else
    echo "安装状态: 未安装"
  fi

  echo -e "\n\033[36m▌ 已安装的数据库客户端工具 ▍\033[0m"
  echo -n "MySQL 客户端: "
  if command -v mysqldump >/dev/null 2>&1; then
    echo "已安装 (mysqldump: $(which mysqldump))"
  else
    echo "未安装"
  fi
  echo -n "PostgreSQL 客户端: "
  if command -v psql >/dev/null 2>&1 && command -v pg_dump >/dev/null 2>&1; then
    echo "已安装 (psql: $(which psql), pg_dump: $(which pg_dump))"
  else
    echo "未安装"
  fi

  echo -e "\n\033[36m▌ 所有计划任务 ▍\033[0m"
  echo -e "优化任务："
  cron_job=$(crontab -l 2>/dev/null | grep "$SCRIPT_PATH")
  if [ -n "$cron_job" ]; then
    cron_min=$(echo "$cron_job" | awk '{print $1}')
    cron_hr=$(echo "$cron_job" | awk '{print $2}')
    cron_day_num=$(echo "$cron_job" | awk '{print $5}')
    cron_day=$(convert_weekday "$cron_day_num")
    printf "  每周 星期%s %02d:%02d 执行 $SCRIPT_PATH\n" "$cron_day" "$cron_hr" "$cron_min"
  else
    echo -e "  \033[33m未设置优化任务\033[0m"
  fi

  echo -e "备份任务："
  if [ -f "$BACKUP_CRON" ]; then
    cat "$BACKUP_CRON" | while read -r line; do
      if [[ "$line" =~ ^[0-9] ]]; then
        cron_min=$(echo "$line" | awk '{print $1}')
        cron_hr=$(echo "$line" | awk '{print $2}')
        cron_day_num=$(echo "$line" | awk '{print $5}')
        cron_day=$(convert_weekday "$cron_day_num")
        cron_cmd=$(echo "$line" | cut -d' ' -f6-)
        printf "  每周 星期%s %02d:%02d 执行 %s\n" "$cron_day" "$cron_hr" "$cron_min" "$cron_cmd"
      fi
    done
  else
    echo -e "  \033[33m未设置备份任务\033[0m"
  fi

  if [ ! -f "$LOG_FILE" ]; then
    echo -e "\n\033[33m警告：日志文件不存在\033[0m"
    return 1
  fi

  start_line=$(grep "=== 优化任务开始 ===" "$LOG_FILE" | tail -1)
  end_line=$(grep "=== 优化任务结束 ===" "$LOG_FILE" | tail -1)
  start_time=$(echo "$start_line" | awk '{print $1 " " $2}')
  end_time=$(echo "$end_line" | awk '{print $1 " " $2}')

  echo -e "\n\033[36m▌ 最近一次优化任务详情 ▍\033[0m"
  if [[ -n "$start_time" && -n "$end_time" ]]; then
    echo "开始时间: $start_time"
    echo "结束时间: $end_time"
    start_seconds=$(date -d "$start_time" +%s 2>/dev/null)
    end_seconds=$(date -d "$end_time" +%s 2>/dev/null)
    if [[ -n "$start_seconds" && -n "$end_seconds" ]]; then
      duration=$((end_seconds - start_seconds))
      echo "执行时长: $duration 秒"
    else
      echo "执行时长: \033[33m无法计算\033[0m"
    fi
    echo -e "执行的任务："
    sed -n "/$start_time - === 优化任务开始 ===/,/$end_time - === 优化任务结束 ===/p" "$LOG_FILE" | grep -v "===" | while read -r line; do
      task=$(echo "$line" | sed 's/^[0-9-]\+ [0-9:]\+ - //')
      if [[ "$task" =~ "完成" || "$task" =~ "没有" || "$task" =~ "清理" ]]; then
        echo "  ✔ $task"
      fi
    done
  else
    echo -e "\033[33m未找到完整的优化任务记录\033[0m"
  fi

  echo -e "\033[34m▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀\033[0m"
}

install_alias() {
  echo -e "\033[36m▶ 快捷命令安装向导\033[0m"
  read -p "请输入命令名称 (默认cristsau): " cmd
  cmd=${cmd:-cristsau}
  if ! [[ "$cmd" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo -e "\033[31m✗ 包含非法字符，只能使用字母数字和下划线\033[0m"
    return 1
  fi
  ln -sf "$(readlink -f "$0")" "/usr/local/bin/$cmd"
  chmod +x "/usr/local/bin/$cmd"
  echo -e "\033[32m✔ 已创建快捷命令：\033[36m$cmd\033[0m"
  echo -e "现在可以直接使用 \033[33m$cmd\033[0m 来启动管理工具"
}

uninstall() {
  echo -e "\033[31m▶ 开始卸载...\033[0m"
  manage_cron
  [ -f "$BACKUP_CRON" ] && rm -v "$BACKUP_CRON"
  [ -f "$CONFIG_FILE" ] && rm -v "$CONFIG_FILE"
  log "所有计划任务和配置文件已移除"
  [ -f "$SCRIPT_PATH" ] && rm -v "$SCRIPT_PATH"
  [ -f "/usr/local/bin/cristsau" ] && rm -v "/usr/local/bin/cristsau"
  echo -e "\n\033[33m⚠ 日志文件仍保留在：$LOG_FILE\033[0m"
  echo -e "\033[31m✔ 卸载完成\033[0m"
}

update_from_github() {
  echo -e "\033[36m▶ 从 GitHub 更新脚本...\033[0m"
  TARGET_DIR="/root/data/cristsau/optimize_server"
  TARGET_PATH="$TARGET_DIR/setup_optimize_server.sh"
  GITHUB_URL="https://raw.githubusercontent.com/cristsau/server-optimization-scripts/main/setup_optimize_server.sh"
  TEMP_FILE="/tmp/setup_optimize_server.sh.tmp"

  if ! wget -O "$TEMP_FILE" "$GITHUB_URL" >/dev/null 2>&1; then
    echo -e "\033[31m✗ 下载失败，请检查网络或 GitHub 地址\033[0m"
    rm -f "$TEMP_FILE"
    return 1
  fi

  LATEST_VERSION=$(grep -m 1 "版本：" "$TEMP_FILE" | awk '{print $NF}')
  echo -e "当前版本: $CURRENT_VERSION"
  echo -e "最新版本: $LATEST_VERSION"

  if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    echo -e "\033[32m✔ 当前已是最新版本\033[0m"
    read -p "是否强制更新？(y/N): " force_update
    if [ "$force_update" != "y" ] && [ "$force_update" != "Y" ]; then
      rm -f "$TEMP_FILE"
      return 0
    fi
  fi

  mkdir -p "$TARGET_DIR"
  mv "$TEMP_FILE" "$TARGET_PATH"
  chmod +x "$TARGET_PATH"

  echo -e "\033[36m清理系统中其他版本的 setup_optimize_server.sh...\033[0m"
  find / -type f -name "setup_optimize_server.sh" -not -path "$TARGET_PATH" -exec rm -v {} \;

  echo -e "\033[32m✔ 脚本更新成功，位置: $TARGET_PATH\033[0m"
  echo -e "正在运行新脚本..."
  sudo "$TARGET_PATH"
}

enable_bbr() {
  echo -e "\033[36m▶ 正在开启 BBR...\033[0m"
  cat > /etc/sysctl.conf << EOF
fs.file-max = 6815744
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 16384 33554432
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
EOF
  if sysctl -p >/dev/null 2>&1 && sysctl --system >/dev/null 2>&1; then
    echo -e "\033[32m✔ BBR 已成功开启\033[0m"
    log "BBR 开启成功"
  else
    echo -e "\033[31m✗ BBR 开启失败，请检查系统配置\033[0m"
    log "BBR 开启失败"
  fi
}

check_backup_tools() {
  local protocol=$1
  case $protocol in
    webdav)
      if ! command -v curl >/dev/null 2>&1; then
        echo -e "\033[31m✗ curl 未安装，请安装：sudo apt-get install curl\033[0m"
        return 1
      fi
      ;;
    ftp)
      if ! command -v ftp >/dev/null 2>&1; then
        echo -e "\033[31m✗ ftp 未安装，请安装：sudo apt-get install ftp\033[0m"
        return 1
      fi
      ;;
    sftp|scp)
      if ! command -v ssh >/dev/null 2>&1; then
        echo -e "\033[31m✗ ssh 未安装，请安装：sudo apt-get install openssh-client\033[0m"
        return 1
      fi
      ;;
    rsync)
      if ! command -v rsync >/dev/null 2>&1; then
        echo -e "\033[31m✗ rsync 未安装，请安装：sudo apt-get install rsync\033[0m"
        return 1
      fi
      ;;
  esac
  return 0
}

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

install_db_client() {
  local db_type=$1
  if [ "$db_type" = "mysql" ]; then
    if ! command -v mysqldump >/dev/null 2>&1; then
      echo -e "\033[33m警告：mysqldump 未安装\033[0m"
      read -p "是否安装 MySQL 客户端？(y/N): " install_choice
      if [ "$install_choice" = "y" ] || [ "$install_choice" = "Y" ]; then
        apt-get update && apt-get install -y mysql-client
        if [ $? -eq 0 ]; then
          echo -e "\033[32m✔ MySQL 客户端安装成功\033[0m"
          log "MySQL 客户端安装成功"
        else
          echo -e "\033[31m✗ MySQL 客户端安装失败\033[0m"
          log "MySQL 客户端安装失败"
          return 1
        fi
      else
        echo -e "\033[31m✗ 未安装 MySQL 客户端，无法备份\033[0m"
        return 1
      fi
    fi
  elif [ "$db_type" = "postgres" ]; then
    if ! command -v pg_dump >/dev/null 2>&1 || ! command -v psql >/dev/null 2>&1; then
      echo -e "\033[33m警告：PostgreSQL 客户端（pg_dump 或 psql）未安装\033[0m"
      read -p "是否安装 PostgreSQL 客户端？(y/N): " install_choice
      if [ "$install_choice" = "y" ] || [ "$install_choice" = "Y" ]; then
        apt-get update && apt-get install -y postgresql-client
        if [ $? -eq 0 ]; then
          echo -e "\033[32m✔ PostgreSQL 客户端安装成功\033[0m"
          log "PostgreSQL 客户端安装成功"
        else
          echo -e "\033[31m✗ PostgreSQL 客户端安装失败\033[0m"
          log "PostgreSQL 客户端安装失败"
          return 1
        fi
      else
        echo -e "\033[31m✗ 未安装 PostgreSQL 客户端，无法备份\033[0m"
        return 1
      fi
    fi
  fi
  return 0
}

backup_menu() {
  while true; do
    clear
    echo -e "\033[34m▌ 备份工具 ▍\033[0m"
    echo -e "\033[36m"
    echo " 1) 备份程序数据"
    echo " 2) 备份数据库"
    echo " 3) 设置备份计划任务"
    echo " 4) 返回"
    echo -e "\033[0m"
    read -p "请输入选项 (1-4): " backup_choice
    case $backup_choice in
      1)
        echo -e "\033[36m▶ 备份程序数据...\033[0m"
        read -p "请输入源路径 (例如 /var/www): " source_path
        read -p "请输入目标路径 (例如 /backup/data 或 http://webdav.example.com): " target_path
        read -p "请输入用户名（本地备份留空）: " username
        if [ -n "$username" ]; then
          read -s -p "请输入密码（或 SSH 密钥路径）: " password
          echo
        fi
        if [ ! -d "$source_path" ]; then
          echo -e "\033[31m✗ 源路径不存在\033[0m"
          continue
        fi
        timestamp=$(date '+%Y%m%d_%H%M%S')
        backup_file="/tmp/backup_data_$timestamp.tar.gz"
        echo -e "\033[36m正在备份 $source_path 到 $backup_file...\033[0m"
        tar -czf "$backup_file" -C "$source_path" . 2>"$TEMP_LOG"
        if [ $? -eq 0 ]; then
          upload_backup "$backup_file" "$target_path" "$username" "$password" && \
          echo -e "\033[32m✔ 备份成功\033[0m" || \
          echo -e "\033[31m✗ 备份失败，请查看日志\033[0m"
        else
          echo -e "\033[31m✗ 备份失败：\033[0m"
          cat "$TEMP_LOG"
          log "程序数据备份失败: $(cat "$TEMP_LOG")"
          rm -f "$backup_file" "$TEMP_LOG"
        fi
        ;;
      2)
        echo -e "\033[36m▶ 备份数据库...\033[0m"
        if load_config; then
          db_type=$DB_TYPE
          db_host=$DB_HOST
          db_port=$DB_PORT
          db_user=$DB_USER
          db_pass=$DB_PASS
          target_path=$TARGET_PATH
          username=$TARGET_USER
          password=$TARGET_PASS
          echo -e "\033[32m✔ 已从配置文件加载参数\033[0m"
        else
          read -p "是否创建配置文件？(y/N): " create_choice
          if [ "$create_choice" = "y" ] || [ "$create_choice" = "Y" ]; then
            create_config
            echo "请编辑 $CONFIG_FILE 并重新运行脚本"
            continue
          fi
          read -p "请输入数据库类型 (mysql/postgres): " db_type
          case "$db_type" in
            mysql|postgres)
              install_db_client "$db_type" || continue
              ;;
            *)
              echo -e "\033[31m✗ 不支持的数据库类型\033[0m"
              continue
              ;;
          esac
          read -p "请输入数据库主机名 (默认 localhost): " db_host
          db_host=${db_host:-localhost}
          read -p "请输入数据库端口 (默认 3306 for MySQL, 5432 for PostgreSQL): " db_port
          db_port=${db_port:-$( [ "$db_type" = "mysql" ] && echo 3306 || echo 5432 )}
          read -p "请输入数据库用户: " db_user
          read -s -p "请输入数据库密码: " db_pass
          echo
          read -p "请输入目标路径 (例如 /backup/db 或 sftp://example.com): " target_path
          read -p "请输入用户名（本地备份留空）: " username
          if [ -n "$username" ]; then
            read -s -p "请输入密码（或 SSH 密钥路径）: " password
            echo
          fi
        fi
        echo -e "\033[36m正在测试数据库连接...\033[0m"
        if [ "$db_type" = "mysql" ]; then
          mysql -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" -e "SHOW DATABASES;" >"$TEMP_LOG" 2>&1
          if [ $? -ne 0 ]; then
            echo -e "\033[31m✗ 数据库连接失败：\033[0m"
            cat "$TEMP_LOG"
            log "MySQL 连接失败: $(cat "$TEMP_LOG")"
            rm -f "$TEMP_LOG"
            continue
          fi
        elif [ "$db_type" = "postgres" ]; then
          export PGPASSWORD="$db_pass"
          psql -h "$db_host" -p "$db_port" -U "$db_user" -d "postgres" -c "SELECT 1;" >"$TEMP_LOG" 2>&1
          if [ $? -ne 0 ]; then
            echo -e "\033[31m✗ 数据库连接失败：\033[0m"
            cat "$TEMP_LOG"
            log "PostgreSQL 连接失败: $(cat "$TEMP_LOG")"
            rm -f "$TEMP_LOG"
            unset PGPASSWORD
            continue
          fi
          unset PGPASSWORD
        fi
        echo -e "\033[32m✔ 数据库连接成功\033[0m"
        rm -f "$TEMP_LOG"
        read -p "是否备份所有数据库？(y/N): " all_dbs
        if [ "$all_dbs" = "y" ] || [ "$all_dbs" = "Y" ]; then
          db_list="all"
        else
          echo -e "\033[36m正在获取数据库列表...\033[0m"
          if [ "$db_type" = "mysql" ]; then
            db_list=$(mysql -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" -e "SHOW DATABASES;" 2>"$TEMP_LOG" | grep -v "Database" | grep -v "information_schema" | grep -v "performance_schema" | grep -v "mysql" | grep -v "sys")
          elif [ "$db_type" = "postgres" ]; then
            export PGPASSWORD="$db_pass"
            db_list=$(psql -h "$db_host" -p "$db_port" -U "$db_user" -d "postgres" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" 2>"$TEMP_LOG" | sed 's/ //g')
            unset PGPASSWORD
            if [ -s "$TEMP_LOG" ]; then
              echo -e "\033[31m✗ 获取数据库列表失败：\033[0m"
              cat "$TEMP_LOG"
              log "获取数据库列表失败: $(cat "$TEMP_LOG")"
              rm -f "$TEMP_LOG"
              continue
            fi
          fi
          if [ -z "$db_list" ]; then
            echo -e "\033[31m✗ 获取数据库列表为空，请检查用户权限或数据库配置\033[0m"
            continue
          fi
          echo -e "可用数据库：\n$db_list"
          read -p "请输入要备份的数据库名称（多个用空格分隔，或输入 all 备份所有）：" db_names
          db_list="$db_names"
        fi
        if [ -z "$target_path" ]; then
          read -p "请输入目标路径 (例如 /backup/db 或 sftp://example.com): " target_path
          read -p "请输入用户名（本地备份留空）: " username
          if [ -n "$username" ]; then
            read -s -p "请输入密码（或 SSH 密钥路径）: " password
            echo
          fi
        fi
        timestamp=$(date '+%Y%m%d_%H%M%S')
        if [ "$db_list" = "all" ]; then
          backup_file="/tmp/all_dbs_$timestamp.sql.gz"
          case "$db_type" in
            mysql)
              echo -e "\033[36m正在备份所有 MySQL 数据库...\033[0m"
              mysqldump -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" --all-databases 2>"$TEMP_LOG" | gzip > "$backup_file"
              ;;
            postgres)
              echo -e "\033[36m正在备份所有 PostgreSQL 数据库...\033[0m"
              export PGPASSWORD="$db_pass"
              pg_dumpall -h "$db_host" -p "$db_port" -U "$db_user" 2>"$TEMP_LOG" | gzip > "$backup_file"
              unset PGPASSWORD
              ;;
          esac
          if [ $? -ne 0 ]; then
            echo -e "\033[31m✗ 备份失败：\033[0m"
            cat "$TEMP_LOG"
            log "备份所有数据库失败: $(cat "$TEMP_LOG")"
            rm -f "$TEMP_LOG" "$backup_file"
            continue
          fi
          upload_backup "$backup_file" "$target_path" "$username" "$password" && \
          echo -e "\033[32m✔ 所有数据库备份成功\033[0m" || \
          echo -e "\033[31m✗ 备份失败，请查看日志\033[0m"
        else
          for db_name in $db_list; do
            backup_file="/tmp/${db_name}_$timestamp.sql.gz"
            case "$db_type" in
              mysql)
                echo -e "\033[36m正在备份 MySQL 数据库 $db_name...\033[0m"
                mysqldump -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" "$db_name" 2>"$TEMP_LOG" | gzip > "$backup_file"
                ;;
              postgres)
                echo -e "\033[36m正在备份 PostgreSQL 数据库 $db_name...\033[0m"
                export PGPASSWORD="$db_pass"
                pg_dump -h "$db_host" -p "$db_port" -U "$db_user" "$db_name" 2>"$TEMP_LOG" | gzip > "$backup_file"
                unset PGPASSWORD
                ;;
            esac
            if [ $? -ne 0 ]; then
              echo -e "\033[31m✗ 备份 $db_name 失败：\033[0m"
              cat "$TEMP_LOG"
              log "备份数据库 $db_name 失败: $(cat "$TEMP_LOG")"
              rm -f "$TEMP_LOG" "$backup_file"
              continue
            fi
            upload_backup "$backup_file" "$target_path" "$username" "$password" && \
            echo -e "\033[32m✔ 数据库 $db_name 备份成功\033[0m" || \
            echo -e "\033[31m✗ 备份 $db_name 失败，请查看日志\033[0m"
          done
        fi
        rm -f "$TEMP_LOG"
        ;;
      3)
        echo -e "\033[36m▶ 设置备份计划任务...\033[0m"
        read -p "请输入备份类型 (1: 程序数据, 2: 数据库): " backup_type
        if [ "$backup_type" = "1" ]; then
          read -p "请输入源路径 (例如 /var/www): " source_path
          if [ ! -d "$source_path" ]; then
            echo -e "\033[31m✗ 源路径不存在\033[0m"
            continue
          fi
          read -p "请输入目标路径 (例如 /backup 或 sftp://example.com): " target_path
          read -p "请输入用户名（本地备份留空）: " username
          if [ -n "$username" ]; then
            read -s -p "请输入密码（或 SSH 密钥路径）: " password
            echo
          fi
        elif [ "$backup_type" = "2" ]; then
          if load_config; then
            db_type=$DB_TYPE
            db_host=$DB_HOST
            db_port=$DB_PORT
            db_user=$DB_USER
            db_pass=$DB_PASS
            target_path=$TARGET_PATH
            username=$TARGET_USER
            password=$TARGET_PASS
            echo -e "\033[32m✔ 已从配置文件加载参数\033[0m"
          else
            read -p "是否创建配置文件？(y/N): " create_choice
            if [ "$create_choice" = "y" ] || [ "$create_choice" = "Y" ]; then
              create_config
              echo "请编辑 $CONFIG_FILE 并重新运行脚本"
              continue
            fi
            read -p "请输入数据库类型 (mysql/postgres): " db_type
            case "$db_type" in
              mysql|postgres)
                install_db_client "$db_type" || continue
                ;;
              *)
                echo -e "\033[31m✗ 不支持的数据库类型\033[0m"
                continue
                ;;
            esac
            read -p "请输入数据库主机名 (默认 localhost): " db_host
            db_host=${db_host:-localhost}
            read -p "请输入数据库端口 (默认 3306 for MySQL, 5432 for PostgreSQL): " db_port
            db_port=${db_port:-$( [ "$db_type" = "mysql" ] && echo 3306 || echo 5432 )}
            read -p "请输入数据库用户: " db_user
            read -s -p "请输入数据库密码: " db_pass
            echo
            read -p "请输入目标路径 (例如 /backup 或 sftp://example.com): " target_path
            read -p "请输入用户名（本地备份留空）: " username
            if [ -n "$username" ]; then
              read -s -p "请输入密码（或 SSH 密钥路径）: " password
              echo
            fi
          fi
          echo -e "\033[36m正在测试数据库连接...\033[0m"
          if [ "$db_type" = "mysql" ]; then
            mysql -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" -e "SHOW DATABASES;" >"$TEMP_LOG" 2>&1
            if [ $? -ne 0 ]; then
              echo -e "\033[31m✗ 数据库连接失败：\033[0m"
              cat "$TEMP_LOG"
              log "MySQL 连接失败: $(cat "$TEMP_LOG")"
              rm -f "$TEMP_LOG"
              continue
            fi
          elif [ "$db_type" = "postgres" ]; then
            export PGPASSWORD="$db_pass"
            psql -h "$db_host" -p "$db_port" -U "$db_user" -d "postgres" -c "SELECT 1;" >"$TEMP_LOG" 2>&1
            if [ $? -ne 0 ]; then
              echo -e "\033[31m✗ 数据库连接失败：\033[0m"
              cat "$TEMP_LOG"
              log "PostgreSQL 连接失败: $(cat "$TEMP_LOG")"
              rm -f "$TEMP_LOG"
              unset PGPASSWORD
              continue
            fi
            unset PGPASSWORD
          fi
          echo -e "\033[32m✔ 数据库连接成功\033[0m"
          rm -f "$TEMP_LOG"
          read -p "是否备份所有数据库？(y/N): " all_dbs
          if [ "$all_dbs" = "y" ] || [ "$all_dbs" = "Y" ]; then
            db_list="all"
          else
            echo -e "\033[36m正在获取数据库列表...\033[0m"
            if [ "$db_type" = "mysql" ]; then
              db_list=$(mysql -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" -e "SHOW DATABASES;" 2>"$TEMP_LOG" | grep -v "Database" | grep -v "information_schema" | grep -v "performance_schema" | grep -v "mysql" | grep -v "sys")
            elif [ "$db_type" = "postgres" ]; then
              export PGPASSWORD="$db_pass"
              db_list=$(psql -h "$db_host" -p "$db_port" -U "$db_user" -d "postgres" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" 2>"$TEMP_LOG" | sed 's/ //g')
              unset PGPASSWORD
              if [ -s "$TEMP_LOG" ]; then
                echo -e "\033[31m✗ 获取数据库列表失败：\033[0m"
                cat "$TEMP_LOG"
                log "获取数据库列表失败: $(cat "$TEMP_LOG")"
                rm -f "$TEMP_LOG"
                continue
              fi
            fi
            if [ -z "$db_list" ]; then
              echo -e "\033[31m✗ 获取数据库列表为空，请检查用户权限或数据库配置\033[0m"
              continue
            fi
            echo -e "可用数据库：\n$db_list"
            read -p "请输入要备份的数据库名称（多个用空格分隔，或输入 all 备份所有）：" db_names
            db_list="$db_names"
          fi
        else
          echo -e "\033[31m✗ 无效备份类型\033[0m"
          continue
        fi
        echo -e "\033[36m设置备份频率：\033[0m"
        echo "  * 表示每天，*/2 表示隔天，0-6 表示特定星期几，1,3,5 表示周一、三、五"
        read -p "请输入 cron 星期字段: " cron_day
        read -p "请输入运行时间 (0-23): " hour
        if [[ ! $hour =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
          echo -e "\033[31m✗ 无效时间输入，必须是 0-23 之间的整数\033[0m"
          continue
        fi
        if [[ "$cron_day" != "*" && "$cron_day" != "*/2" && ! "$cron_day" =~ ^([0-6](,[0-6])*)$ ]]; then
          echo -e "\033[31m✗ 无效星期字段，请输入 *、*/2 或 0-6 的数字（可用逗号分隔）\033[0m"
          continue
        fi
        cron_cmd=""
        if [ "$backup_type" = "1" ]; then
          cron_cmd="bash -c 'tar -czf /tmp/backup_data_\$(date +\%Y\%m\%d_\%H\%M\%S).tar.gz -C $source_path . && "
          if [[ "$target_path" =~ ^http ]]; then
            cron_cmd+="curl -u $username:$password -T /tmp/backup_data_\$(date +\%Y\%m\%d_\%H\%M\%S).tar.gz $target_path/backup_data_\$(date +\%Y\%m\%d_\%H\%M\%S).tar.gz && rm -f /tmp/backup_data_\$(date +\%Y\%m\%d_\%H\%M\%S).tar.gz'"
          elif [[ "$target_path" =~ ^ftp ]]; then
            cron_cmd+="ftp -n ${target_path#ftp://} <<EOF
user $username $password
put /tmp/backup_data_\$(date +\%Y\%m\%d_\%H\%M\%S).tar.gz backup_data_\$(date +\%Y\%m\%d_\%H\%M\%S).tar.gz
bye
EOF && rm -f /tmp/backup_data_\$(date +\%Y\%m\%d_\%H\%M\%S).tar.gz'"
          elif [[ "$target_path" =~ ^sftp ]]; then
            cron_cmd+="echo \"put /tmp/backup_data_\$(date +\%Y\%m\%d_\%H\%M\%S).tar.gz backup_data_\$(date +\%Y\%m\%d_\%H\%M\%S).tar.gz\" | sftp -b - -i $password $username@${target_path#sftp://} && rm -f /tmp/backup_data_\$(date +\%Y\%m\%d_\%H\%M\%S).tar.gz'"
          elif [[ "$target_path" =~ ^rsync ]]; then
            cron_cmd+="rsync -e \"ssh -i $password\" /tmp/backup_data_\$(date +\%Y\%m\%d_\%H\%M\%S).tar.gz $username@${target_path#rsync://}:backup_data_\$(date +\%Y\%m\%d_\%H\%M\%S).tar.gz && rm -f /tmp/backup_data_\$(date +\%Y\%m\%d_\%H\%M\%S).tar.gz'"
          else
            cron_cmd+="mkdir -p $target_path && mv /tmp/backup_data_\$(date +\%Y\%m\%d_\%H\%M\%S).tar.gz $target_path/'"
          fi
        elif [ "$backup_type" = "2" ]; then
          if [ "$db_list" = "all" ]; then
            if [ "$db_type" = "mysql" ]; then
              cron_cmd="bash -c 'mysqldump -h $db_host -P $db_port -u $db_user -p$db_pass --all-databases | gzip > /tmp/all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz && "
            elif [ "$db_type" = "postgres" ]; then
              cron_cmd="bash -c 'PGPASSWORD=$db_pass pg_dumpall -h $db_host -p $db_port -U $db_user | gzip > /tmp/all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz && "
            fi
            if [[ "$target_path" =~ ^http ]]; then
              cron_cmd+="curl -u $username:$password -T /tmp/all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz $target_path/all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz && rm -f /tmp/all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz'"
            elif [[ "$target_path" =~ ^ftp ]]; then
              cron_cmd+="ftp -n ${target_path#ftp://} <<EOF
user $username $password
put /tmp/all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz
bye
EOF && rm -f /tmp/all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz'"
            elif [[ "$target_path" =~ ^sftp ]]; then
              cron_cmd+="echo \"put /tmp/all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz\" | sftp -b - $username@${target_path#sftp://} && rm -f /tmp/all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz'"
            elif [[ "$target_path" =~ ^rsync ]]; then
              cron_cmd+="rsync -e \"ssh -i $password\" /tmp/all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz $username@${target_path#rsync://}:all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz && rm -f /tmp/all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz'"
            else
              cron_cmd+="mkdir -p $target_path && mv /tmp/all_dbs_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz $target_path/'"
            fi
          else
            for db_name in $db_list; do
              if [ "$db_type" = "mysql" ]; then
                cron_cmd="bash -c 'mysqldump -h $db_host -P $db_port -u $db_user -p$db_pass $db_name | gzip > /tmp/${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz && "
              elif [ "$db_type" = "postgres" ]; then
                cron_cmd="bash -c 'PGPASSWORD=$db_pass pg_dump -h $db_host -p $db_port -U $db_user $db_name | gzip > /tmp/${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz && "
              fi
              if [[ "$target_path" =~ ^http ]]; then
                cron_cmd+="curl -u $username:$password -T /tmp/${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz $target_path/${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz && rm -f /tmp/${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz'"
              elif [[ "$target_path" =~ ^ftp ]]; then
                cron_cmd+="ftp -n ${target_path#ftp://} <<EOF
user $username $password
put /tmp/${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz ${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz
bye
EOF && rm -f /tmp/${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz'"
              elif [[ "$target_path" =~ ^sftp ]]; then
                cron_cmd+="echo \"put /tmp/${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz ${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz\" | sftp -b - $username@${target_path#sftp://} && rm -f /tmp/${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz'"
              elif [[ "$target_path" =~ ^rsync ]]; then
                cron_cmd+="rsync -e \"ssh -i $password\" /tmp/${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz $username@${target_path#rsync://}:${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz && rm -f /tmp/${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz'"
              else
                cron_cmd+="mkdir -p $target_path && mv /tmp/${db_name}_\$(date +\%Y\%m\%d_\%H\%M\%S).sql.gz $target_path/'"
              fi
              echo "0 $hour * * $cron_day root $cron_cmd" >> "$BACKUP_CRON"
            done
            chmod 644 "$BACKUP_CRON"
            echo -e "\033[32m✔ 备份计划任务设置成功\033[0m"
            log "备份计划任务设置成功: 星期字段 $cron_day 的 $hour:00"
            continue
          fi
        fi
        echo "0 $hour * * $cron_day root $cron_cmd" > "$BACKUP_CRON"
        chmod 644 "$BACKUP_CRON"
        echo -e "\033[32m✔ 备份计划任务设置成功\033[0m"
        log "备份计划任务设置成功: 星期字段 $cron_day 的 $hour:00"
        ;;
      4) return ;;
      *)
        echo -e "\033[31m无效选项，请输入 1-4\033[0m"
        ;;
    esac
    read -p "按回车继续..."
  done
}

toolbox_menu() {
  while true; do
    clear
    echo -e "\033[34m▌ 工具箱 ▍\033[0m"
    echo -e "\033[36m"
    echo " 1) 升级或安装最新 Docker"
    echo " 2) 同步服务器时间"
    echo " 3) 开启 BBR"
    echo " 4) 备份工具"
    echo " 5) 退出"
    echo -e "\033[0m"
    read -p "请输入选项 (1-5): " tool_choice
    case $tool_choice in
      1)
        echo -e "\033[36m▶ 检查 Docker 状态...\033[0m"
        if ! command -v curl >/dev/null 2>&1 || ! command -v apt-cache >/dev/null 2>&1; then
          echo -e "\033[31m✗ 缺少必要工具（curl 或 apt-cache），请先安装\033[0m"
          echo "安装命令: sudo apt-get install -y curl apt"
          continue
        fi
        if command -v docker >/dev/null 2>&1; then
          current_version=$(docker --version | awk '{print $3}' | sed 's/,//')
          echo -e "当前 Docker 版本: $current_version"
          if ! grep -r "download.docker.com" /etc/apt/sources.list /etc/apt/sources.list.d/ >/dev/null 2>&1; then
            echo -e "\033[36m添加 Docker 官方 APT 源...\033[0m"
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add - >/dev/null 2>&1
            echo "deb [arch=amd64] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
          fi
          sudo apt-get update -qq >/dev/null 2>&1
          latest_version=$(apt-cache madison docker-ce | grep -oP '\d+\.\d+\.\d+' | head -1)
          if [ -z "$latest_version" ]; then
            echo -e "\033[31m✗ 无法获取最新 Docker 版本，请检查网络或 APT 源\033[0m"
            continue
          fi
          echo -e "最新 Docker 版本: $latest_version"
          if [ "$current_version" = "$latest_version" ]; then
            echo -e "\033[32m✔ 当前已是最新版本，无需升级\033[0m"
            read -p "是否强制重新安装？(y/N): " force_install
            if [ "$force_install" != "y" ] && [ "$force_install" != "Y" ]; then
              continue
            fi
          fi
        else
          echo -e "\033[33m未检测到 Docker，将安装最新版本\033[0m"
          echo -e "\033[36m添加 Docker 官方 APT 源...\033[0m"
          curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add - >/dev/null 2>&1
          echo "deb [arch=amd64] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
          sudo apt-get update -qq >/dev/null 2>&1
        fi
        echo -e "\033[36m▶ 正在升级或安装最新 Docker...\033[0m"
        curl -fsSL https://get.docker.com | sudo sh
        if [ $? -eq 0 ]; then
          echo -e "\033[32m✔ Docker 安装/升级成功\033[0m"
          log "Docker 安装或升级完成"
        else
          echo -e "\033[31m✗ Docker 安装/升级失败\033[0m"
          log "Docker 安装或升级失败"
        fi
        ;;
      2)
        echo -e "\033[36m▶ 正在同步服务器时间...\033[0m"
        sudo apt-get update && \
        sudo apt-get install -y systemd-timesyncd && \
        sudo systemctl enable systemd-timesyncd && \
        sudo systemctl start systemd-timesyncd && \
        sudo timedatectl set-ntp true && \
        timedatectl status
        if [ $? -eq 0 ]; then
          echo -e "\033[32m✔ 服务器时间同步成功\033[0m"
          log "服务器时间同步完成"
        else
          echo -e "\033[31m✗ 服务器时间同步失败\033[0m"
          log "服务器时间同步失败"
        fi
        ;;
      3)
        enable_bbr
        ;;
      4)
        backup_menu
        ;;
      5) return ;;
      *) echo -e "\033[31m无效选项，请重新输入\033[0m" ;;
    esac
    read -p "按回车继续..."
  done
}

show_menu() {
  clear
  echo -e "\033[34m
   ██████╗██████╗ ██╗███████╗████████╗███████╗ █████╗ ██╗   ██╗
  ██╔════╝██╔══██╗██║██╔════╝╚══██╔══╝██╔════╝██╔══██╗██║   ██║
  ██║     ██████╔╝██║███████╗   ██║   ███████╗███████║██║   ██║
  ██║     ██╔══██╗██║╚════██║   ██║   ╚════██║██╔══██║██║   ██║
  ╚██████╗██║  ██║██║███████║   ██║   ███████║██║  ██║╚██████╔╝
   ╚═════╝╚═╝  ╚═╝╚═╝╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝ ╚═════╝ 
  \033[0m"
  echo -e "\033[36m"
  echo " 1) 安装/配置优化脚本"
  echo " 2) 实时监控日志"
  echo " 3) 查看任务状态"
  echo " 4) 手动执行优化任务"
  echo " 5) 创建快捷命令"
  echo " 6) 完全卸载本工具"
  echo " 7) 工具箱"
  echo " 8) 从 GitHub 更新脚本"
  echo " 9) 退出"
  echo -e "\033[0m"
}

while true; do
  show_menu
  read -p "请输入选项 (1-9): " choice
  case $choice in
    1) install_script ;;
    2) 
      echo "正在实时监控日志文件：$LOG_FILE"
      echo "提示：请在新终端中选择选项 4 手动执行优化任务，以观察实时日志更新"
      echo "按 Ctrl+C 退出监控"
      tail -f "$LOG_FILE"
      ;;
    3) view_status && read -p "按回车返回菜单..." ;;
    4) "$SCRIPT_PATH" ;;
    5) install_alias ;;
    6) uninstall && exit ;;
    7) toolbox_menu ;;
    8) update_from_github ;;
    9) exit 0 ;;
    *) echo -e "\033[31m无效选项，请重新输入\033[0m" ;;
  esac
  read -p "按回车继续..."
done