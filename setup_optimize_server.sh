#!/bin/bash

# 脚本名称：setup_optimize_server.sh
# 作者：cristsau
# 版本：3.4
# 功能：服务器优化管理工具

if [ "$(id -u)" -ne 0 ]; then
  echo -e "\033[31m✗ 请使用 root 权限运行此脚本\033[0m"
  exit 1
fi

SCRIPT_NAME="optimize_server.sh"
SCRIPT_PATH="/usr/local/bin/$SCRIPT_NAME"
LOG_FILE="/var/log/optimize_server.log"
TEMP_LOG="/tmp/optimize_temp.log"

log() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "$timestamp - $1" | tee -a "$LOG_FILE"
  if [ -z "$INSTALL_MODE" ]; then
    echo "$timestamp - 调试：日志写入到 $LOG_FILE" | tee -a "$LOG_FILE"
  fi
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
    log "已设置计划任务：每周 $cron_day 的 $cron_hr:00"
  fi
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
  if [ -z "\$INSTALL_MODE" ]; then
    echo "\$timestamp - 调试：日志写入到 \$LOG_FILE" | tee -a "\$LOG_FILE"
  fi
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
  log "调试：确认任务开始已记录"
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

  if [ ! -f "$LOG_FILE" ]; then
    echo -e "\033[33m警告：日志文件不存在\033[0m"
    return 1
  fi

  start_line=$(grep "=== 优化任务开始 ===" "$LOG_FILE" | tail -1)
  end_line=$(grep "=== 优化任务结束 ===" "$LOG_FILE" | tail -1)
  start_time=$(echo "$start_line" | awk '{print $1 " " $2}')
  end_time=$(echo "$end_line" | awk '{print $1 " " $2}')

  echo -e "\n🕒 最近一次执行详情："
  echo "   • 日志文件路径: $LOG_FILE"
  echo "   • 日志文件大小: $(du -h "$LOG_FILE" | cut -f1)"
  if [[ -n "$start_time" && -n "$end_time" ]]; then
    echo "   • 开始时间: $start_time"
    echo "   • 结束时间: $end_time"
    start_seconds=$(date -d "$start_time" +%s 2>/dev/null)
    end_seconds=$(date -d "$end_time" +%s 2>/dev/null)
    if [[ -n "$start_seconds" && -n "$end_seconds" ]]; then
      duration=$((end_seconds - start_seconds))
      echo "   • 执行时长: $duration 秒"
    else
      echo "   • 执行时长: \033[33m无法计算\033[0m"
    fi
    echo -e "   • 上一次执行的任务："
    sed -n "/$start_time - === 优化任务开始 ===/,/$end_time - === 优化任务结束 ===/p" "$LOG_FILE" | grep -v "调试" | grep -v "===" | while read -r line; do
      task=$(echo "$line" | sed 's/^[0-9-]\+ [0-9:]\+ - //')
      if [[ "$task" =~ "完成" || "$task" =~ "没有" || "$task" =~ "清理" ]]; then
        echo "     ✔ $task"
      fi
    done
  else
    echo -e "   • \033[33m未找到完整的执行记录\033[0m"
  fi

  cron_job=$(crontab -l 2>/dev/null | grep "$SCRIPT_PATH")
  if [ -n "$cron_job" ]; then
    cron_min=$(echo "$cron_job" | awk '{print $1}')
    cron_hr=$(echo "$cron_job" | awk '{print $2}')
    cron_day_num=$(echo "$cron_job" | awk '{print $5}')
    cron_day=$(convert_weekday "$cron_day_num")
    echo -e "\n当前计划任务："
    printf "  每周 星期%s %02d:%02d\n" "$cron_day" "$cron_hr" "$cron_min"
    current_day=$(date +%w)
    current_hour=$(date +%H | sed 's/^0//')
    current_min=$(date +%M | sed 's/^0//')
    if [[ $current_day -lt $cron_day_num ]] || \
       ([[ $current_day -eq $cron_day_num ]] && [[ $current_hour -lt $cron_hr ]]) || \
       ([[ $current_day -eq $cron_day_num ]] && [[ $current_hour -eq $cron_hr ]] && [[ $current_min -lt $cron_min ]]); then
      days_until=$((cron_day_num - current_day))
    else
      days_until=$((7 - current_day + cron_day_num))
    fi
    next_run=$(date -d "+$days_until days $cron_hr:$cron_min" "+%Y-%m-%d %H:%M")
    echo -e "下次执行时间：\n  $next_run"
    echo -e "\n下次执行任务："
    echo "  ✔ 检查必要的工具和服务"
    echo "  ✔ 配置脚本日志轮转"
    echo "  ✔ 配置系统日志轮转"
    echo "  ✔ 清理超过15天的旧系统日志"
    echo "  ✔ 配置 Docker 日志轮转"
    echo "  ✔ 清理 Docker 容器日志"
    echo "  ✔ 清理 APT 缓存"
    echo "  ✔ 清理旧内核版本"
    echo "  ✔ 清理 /tmp 目录"
    echo "  ✔ 清理用户缓存"
  else
    echo -e "当前计划任务：\033[33m未设置\033[0m"
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
  log "计划任务已移除"
  [ -f "$SCRIPT_PATH" ] && rm -v "$SCRIPT_PATH"
  [ -f "/usr/local/bin/cristsau" ] && rm -v "/usr/local/bin/cristsau"
  echo -e "\n\033[33m⚠ 日志文件仍保留在：$LOG_FILE\033[0m"
  echo -e "\033[31m✔ 卸载完成\033[0m"
}

toolbox_menu() {
  while true; do
    clear
    echo -e "\033[34m▌ 工具箱 ▍\033[0m"
    echo -e "\033[36m"
    echo " 1) 升级或安装最新 Docker"
    echo " 2) 同步服务器时间"
    echo " 3) 退出"
    echo -e "\033[0m"
    read -p "请输入选项 (1-3): " tool_choice
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
      3) return ;;
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
  echo " 8) 退出"
  echo -e "\033[0m"
}

while true; do
  show_menu
  read -p "请输入选项 (1-8): " choice
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
    8) exit 0 ;;
    *) echo -e "\033[31m无效选项，请重新输入\033[0m" ;;
  esac
  read -p "按回车继续..."
done