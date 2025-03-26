#!/bin/bash

# 脚本名称：setup_optimize_server.sh
# 描述：用于安装、查看日志和卸载 optimize_server.sh 脚本
# 使用方法：sudo ./setup_optimize_server.sh

# 确保以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 权限运行此脚本。"
  exit 1
fi

# 定义常量
SCRIPT_NAME="optimize_server.sh"
SCRIPT_PATH="/usr/local/bin/$SCRIPT_NAME"
LOG_FILE="/var/log/optimize_server.log"

# 检查脚本是否存在
check_script_exists() {
  if [ -f "$SCRIPT_PATH" ]; then
    return 0
  else
    return 1
  fi
}

# 检查 /var/log 是否可写
check_log_writable() {
  if [ ! -w /var/log ]; then
    LOG_FILE="/tmp/optimize_server.log"
    echo "警告：/var/log 不可写，日志将保存到 $LOG_FILE"
  fi
}

# 记录日志
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 显示菜单
show_menu() {
  echo "请选择一个选项:"
  echo "1. 安装脚本"
  echo "2. 查看日志 (tail -f /var/log/optimize_server.log)"
  echo "3. 手动更新系统和软件包"
  echo "4. 卸载脚本"
  echo "5. 退出"
}

# 安装脚本
install_script() {
  log "开始安装优化脚本..."

  # 提示用户输入自动运行的时间
  read -p "请输入脚本每周自动运行的星期几 (0-6, 其中 0 表示星期日): " day_of_week
  read -p "请输入脚本自动运行的小时 (0-23): " hour_of_day

  # 验证输入
  if ! [[ "$day_of_week" =~ ^[0-9]$ ]] || ! [[ "$hour_of_day" =~ ^[0-9]{1,2}$ ]]; then
    echo "输入无效，请重新运行脚本并输入有效的星期几和小时。"
    log "错误: 输入无效的自动运行时间。"
    exit 1
  fi

  # 创建脚本文件
  cat <<EOF > "$SCRIPT_PATH"
#!/bin/bash

# 脚本名称：optimize_server.sh
# 描述：通用的云服务器优化脚本，适用于 Debian 系统，适合定期自动执行。
# 使用方法：sudo optimize_server.sh

# 确保以 root 权限运行
if [ "\$(id -u)" -ne 0 ]; then
  echo "请以 root 权限运行此脚本。"
  exit 1
fi

# 日志文件路径
LOG_FILE="$LOG_FILE"

# 检查 /var/log 是否可写
if [ ! -w /var/log ]; then
  LOG_FILE="/tmp/optimize_server.log"
  echo "警告：/var/log 不可写，日志将保存到 \$LOG_FILE"
fi

# 记录日志
log() {
  echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" | tee -a "\$LOG_FILE"
}

# 配置脚本日志轮转
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
  logrotate -f /etc/logrotate.conf
  log "脚本日志轮转配置完成。"
}

# 检查必要的工具和服务
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

# 函数：显示磁盘使用情况
show_disk_usage() {
  log "当前磁盘使用情况："
  df -h >> "\$LOG_FILE"
}

# 函数：配置 logrotate
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
  logrotate -f /etc/logrotate.conf
  log "logrotate 配置完成。"
}

# 函数：清理旧系统日志
clean_old_syslogs() {
  log "清理超过 15 天的旧系统日志..."
  find /var/log -type f -name "*.log" -mtime +15 -exec rm {} \\; 2>> "\$LOG_FILE"
  log "旧系统日志清理完成。"
}

# 函数：配置 Docker 日志轮转
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
  log "Docker 日志轮转配置完成，但未重启 Docker 服务。请手动重启 Docker 服务以应用更改。"
}

# 函数：清理 Docker 容器日志
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

# 函数：清理 APT 缓存
clean_apt_cache() {
  log "清理 APT 缓存..."
  apt-get clean
  log "APT 缓存清理完成。"
}

# 函数：清理旧内核版本
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
    log "没有旧内核版本需要清理。"
  fi
}

# 函数：清理临时文件
clean_tmp_files() {
  log "清理 /tmp 目录..."
  if [ -d /tmp ]; then
    rm -rf /tmp/*
    log "临时文件清理完成。"
  else
    log "警告：/tmp 目录不存在，跳过清理。"
  fi
}

# 函数：清理用户缓存
clean_user_cache() {
  log "清理用户缓存..."
  for user in \$(ls /home); do
    cache_dir="/home/\$user/.cache"
    if [ -d "\$cache_dir" ]; then
      rm -rf "\$cache_dir/*"
      log "清理 \$user 的缓存完成。"
    fi
  done
  if [ -d /root/.cache ]; then
    rm -rf /root/.cache/*
    log "清理 root 用户的缓存完成。"
  fi
  log "用户缓存清理完成。"
}

# 主函数
main() {
  log "开始优化云服务器..."
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
  log "优化和清理完成。"
}

# 运行主函数
main
EOF

  # 赋予脚本执行权限
  chmod +x "$SCRIPT_PATH"
  log "脚本已安装到 $SCRIPT_PATH"

  # 设置 cron 作业
  (crontab -l 2>/dev/null; echo "$((10#$hour_of_day)) $((10#$day_of_week)) * * * $SCRIPT_PATH") | crontab -
  log "Cron 作业已设置为每周 $day_of_week 的 $hour_of_day:00 自动运行脚本。"

  # 手动测试脚本
  echo "正在手动测试脚本..."
  $SCRIPT_PATH

  # 检查测试结果
  if grep -q "优化和清理完成" "$LOG_FILE"; then
    echo "脚本测试成功，日志位于 $LOG_FILE"
    log "脚本测试成功。"
  else
    echo "脚本测试失败，请检查日志 $LOG_FILE"
    log "脚本测试失败。"
  fi
}

# 查看日志
view_log() {
  if [ -f "$LOG_FILE" ]; then
    tail -f "$LOG_FILE"
  else
    echo "日志文件 $LOG_FILE 不存在。"
  fi
}

# 手动更新系统和软件包
manual_update() {
  if check_script_exists; then
    log "手动更新系统和软件包..."
    apt-get update
    apt-get upgrade -y
    log "系统和软件包更新完成。"
  else
    echo "脚本 $SCRIPT_PATH 未安装。"
    log "错误: 脚本 $SCRIPT_PATH 未安装，无法手动更新系统和软件包。"
  fi
}

# 卸载脚本
uninstall_script() {
  if check_script_exists; then
    # 删除脚本文件
    rm -f "$SCRIPT_PATH"
    log "脚本 $SCRIPT_PATH 已删除"

    # 删除 cron 作业
    crontab -l | grep -v "$SCRIPT_PATH" | crontab -
    log "Cron 作业已删除"

    # 删除日志文件
    rm -f "$LOG_FILE"
    log "日志文件 $LOG_FILE 已删除"

    echo "脚本已完全卸载。"
  else
    echo "脚本 $SCRIPT_PATH 未安装。"
  fi
}

# 主循环
while true; do
  clear
  show_menu
  read -p "请输入选项 (1-5): " choice
  case $choice in
    1)
      install_script
      ;;
    2)
      view_log
      ;;
    3)
      manual_update
      ;;
    4)
      uninstall_script
      ;;
    5)
      echo "退出脚本。"
      exit 0
      ;;
    *)
      echo "无效的选项，请重新输入。"
      ;;
  esac
  read -p "按 Enter 键继续..."
done
