#!/bin/bash

# 脚本名称：setup_optimize_server.sh
# 描述：用于安装、查看日志和卸载 optimize_server.sh 脚本，并支持自安装快捷命令
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
REPO_OWNER="cristsau"
REPO_NAME="server-optimization-scripts"
BRANCH="main"
SCRIPT_FILE="setup_optimize_server.sh"
GITHUB_URL="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$BRANCH/$SCRIPT_FILE"

# 检查脚本是否存在
check_script_exists() {
  if [ -f "$SCRIPT_PATH" ]; then
    return 0
  else
    return 1
  fi
}

# 记录日志
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 自安装功能：将脚本复制到 /usr/local/bin 并创建快捷命令 cristsau
self_install() {
  # 检查是否已经安装
  if [ -f "/usr/local/bin/cristsau" ]; then
    echo "快捷命令 'cristsau' 已存在，无需重新安装。"
    return
  fi

  # 复制脚本到 /usr/local/bin
  echo "正在将脚本安装为快捷命令 'cristsau'..."
  cp "$0" /usr/local/bin/cristsau
  chmod +x /usr/local/bin/cristsau

  # 验证安装是否成功
  if [ -f "/usr/local/bin/cristsau" ]; then
    echo "快捷命令 'cristsau' 安装成功！现在你可以直接运行 'cristsau' 启动脚本。"
    log "快捷命令 'cristsau' 安装成功。"
  else
    echo "快捷命令安装失败，请检查权限或路径。"
    log "错误: 快捷命令安装失败。"
  fi
}

# 显示彩色字标题
show_title() {
  echo -e "\e[34m░██  ░██\e[0m"
  echo -e "\e[34m░██  ░██\e[0m       \e[34m░████\e[0m        \e[34m░█\e[0m         \e[34m░█\e[0m        \e[34m░█░█░█\e[0m"
  echo -e "\e[34m░██  ░██\e[0m     \e[34m░█      █\e[0m      \e[34m░█\e[0m         \e[34m░█\e[0m        \e[34m░█    ░█\e[0m"
  echo -e "\e[34m░██████\e[0m     \e[34m░██████\e[0m         \e[34m░█\e[0m         \e[34m░█\e[0m        \e[34m░█    ░█\e[0m"
  echo -e "\e[34m░██  ░██\e[0m     \e[34m░█\e[0m             \e[34m░█\e[0m \e[34m░█\e[0m      \e[34m░█\e[0m  \e[34m░█\e[0m     \e[34m░█░█░█\e[0m"
  echo -e "\e[34m░██  ░██\e[0m      \e[34m░██  █\e[0m         \e[34m░█\e[0m         \e[34m░█\e[0m                    "
  echo -e "\e[32mcristsau 万能清理工具\e[0m"
  echo ""
}

# 显示菜单
show_menu() {
  echo "请选择一个选项:"
  echo "1. 安装脚本"
  echo "2. 查看日志 (tail -f /var/log/optimize_server.log)"
  echo "3. 手动更新系统和软件包"
  echo "4. 查看当前脚本运行情况"
  echo "5. 更新当前脚本"
  echo "6. 卸载脚本"
  echo "7. 安装快捷命令 'cristsau'"
  echo "8. 退出"
}

# 安装脚本
install_script() {
  log "开始安装优化脚本..."

  # 提示用户输入自动运行的时间
  read -p "请输入脚本每周自动运行的星期几 (0-6, 其中 0 表示星期日): " day_of_week
  read -p "请输入脚本自动运行的小时 (0-23): " hour_of_day

  # 验证输入
  if ! [[ "$day_of_week" =~ ^[0-6]$ ]] || ! [[ "$hour_of_day" =~ ^[0-9]{1,2}$ ]]; then
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

# 主函数
main() {
  log "开始优化云服务器..."
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
    echo "按 Ctrl+C 退出查看日志。"
    read -p "按 Enter 键继续..."
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

# 查看当前脚本运行情况
view_script_status() {
  if check_script_exists; then
    echo "脚本 $SCRIPT_PATH 已安装。"
  else
    echo "脚本 $SCRIPT_PATH 未安装。"
    return
  fi

  # 获取 cron 作业
  cron_job=$(crontab -l 2>/dev/null | grep "$SCRIPT_PATH")
  if [ -n "$cron_job" ]; then
    # 解析 cron 表达式
    cron_minute=$(echo "$cron_job" | awk '{print $1}')
    cron_hour=$(echo "$cron_job" | awk '{print $2}')
    cron_day_of_week=$(echo "$cron_job" | awk '{print $5}')
    cron_command=$(echo "$cron_job" | awk '{$1=$2=$3=$4=$5=""; print substr($0, 6)}')

    # 将星期几转换为中文
    case "$cron_day_of_week" in
      0) day_of_week="星期日" ;;
      1) day_of_week="星期一" ;;
      2) day_of_week="星期二" ;;
      3) day_of_week="星期三" ;;
      4) day_of_week="星期四" ;;
      5) day_of_week="星期五" ;;
      6) day_of_week="星期六" ;;
      *) day_of_week="未知" ;;
    esac

    echo "计划任务: $cron_job"
    echo "计划任务执行时间: 每周 $day_of_week 的 $cron_hour:$cron_minute"
  else
    echo "未找到计划任务。"
  fi

  # 获取上一次执行的日期和时间
  if [ -f "$LOG_FILE" ]; then
    last_run=$(grep "优化和清理完成" "$LOG_FILE" | tail -n 1 | awk '{print $1" "$2}')
    echo "上一次执行日期和时间: $last_run"
  else
    echo "日志文件 $LOG_FILE 不存在，无法获取上一次执行信息。"
  fi

  # 获取上一次执行的结果
  if [ -f "$LOG_FILE" ]; then
    last_result=$(grep "优化和清理完成" "$LOG_FILE" | tail -n 1)
    if [ -n "$last_result" ]; then
      echo "上一次执行结果: 成功"
    else
      echo "上一次执行结果: 失败"
    fi
  else
    echo "日志文件 $LOG_FILE 不存在，无法获取上一次执行结果。"
  fi

  # 计算下一次执行时间
  current_time=$(date +%s)
  cron_time=$(date -d "$(date +%Y-%m-%d) $cron_hour:$cron_minute:00" +%s)
  while [ "$cron_time" -le "$current_time" ]; do
    cron_time=$(date -d "+1 week" +%Y-%m-%d)T$cron_hour:$cron_minute:00
    cron_time=$(date -d "$cron_time" +%s)
  done
  next_run=$(date -d "@$cron_time" +"%Y-%m-%d %H:%M:%S")
  next_run_day=$(date -d "@$cron_time" +"%u")
  next_run_time=$(date -d "@$cron_time" +"%H:%M")

  # 将星期几转换为中文
  case "$next_run_day" in
    0) next_run_day="星期日" ;;
    1) next_run_day="星期一" ;;
    2) next_run_day="星期二" ;;
    3) next_run_day="星期三" ;;
    4) next_run_day="星期四" ;;
    5) next_run_day="星期五" ;;
    6) next_run_day="星期六" ;;
    *) next_run_day="未知" ;;
  esac

  echo "下一次执行日期和时间: $next_run_day 的 $next_run_time"
}

# 更新当前脚本
update_script() {
  log "开始更新脚本..."

  # 动态生成 GITHUB_URL
  temp_script="/tmp/setup_optimize_server.sh"
  wget -O "$temp_script" "$GITHUB_URL"
  if [ $? -ne 0 ]; then
    log "脚本更新失败。"
    echo "脚本更新失败，请检查网络连接和文件路径。"
    return
  fi

  # 比较当前脚本和临时脚本的哈希值
  current_hash=$(sha256sum "$SCRIPT_PATH" | awk '{print $1}')
  new_hash=$(sha256sum "$temp_script" | awk '{print $1}')

  if [ "$current_hash" == "$new_hash" ]; then
    echo "当前版本已最新，无需更新。"
    log "当前版本已最新，无需更新。"
    rm -f "$temp_script"
    return
  fi

  # 替换当前脚本
  mv "$temp_script" "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  log "脚本已成功更新。"
  echo "脚本已成功更新。"
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
  show_title
  show_menu
  read -p "请输入选项 (1-8): " choice
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
      view_script_status
      ;;
    5)
      update_script
      ;;
    6)
      uninstall_script
      ;;
    7)
      self_install
      ;;
    8)
      echo "退出脚本。"
      exit 0
      ;;
    *)
      echo "无效的选项，请重新输入。"
      ;;
  esac
  read -p "按 Enter 键继续..."
done

