#!/bin/bash
# lib_toolbox.sh - Toolbox functions

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
# Assume CURRENT_VERSION is accessible
source "$SCRIPT_DIR/lib_utils.sh" # For log, clear_cmd, check_command
source "$SCRIPT_DIR/lib_backup.sh" # For backup_menu

# --- Functions ---
InstallDocker(){
    log "运行 Docker 安装/升级程序"
    echo -e "\033[36m▶ 检查并安装/升级 Docker...\033[0m"
    check_command "curl" || return 1
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
    log "运行时间同步程序"
    echo -e "\033[36m▶ 正在同步服务器时间 (使用 systemd-timesyncd)...\033[0m"
    check_command "timedatectl" || return 1; check_command "systemctl" || return 1; check_command "apt-get" || return 1; check_command "dpkg" || return 1;

    echo "检查 timesyncd 服务状态...";
    if ! dpkg -s systemd-timesyncd >/dev/null 2>&1; then
         echo "未找到 systemd-timesyncd，尝试安装..."; apt-get update -qq && apt-get install -y systemd-timesyncd || { echo "安装失败"; log "安装timesyncd失败"; return 1; }
    fi
    echo "启用并重启 systemd-timesyncd 服务...";
    systemctl enable systemd-timesyncd > /dev/null 2>&1; systemctl restart systemd-timesyncd; sleep 2;
    if systemctl is-active --quiet systemd-timesyncd; then
        echo -e "\033[32m✔ systemd-timesyncd 服务运行中。\033[0m"; echo "设置系统时钟使用 NTP 同步..."; timedatectl set-ntp true
         if [ $? -eq 0 ]; then echo -e "\033[32m✔ NTP 同步已启用。\033[0m"; log "时间同步配置完成"; else echo -e "\033[31m✗ 启用 NTP 同步失败。\033[0m"; log "启用 NTP 同步失败"; fi;
         echo "当前时间状态："; timedatectl status;
    else echo -e "\033[31m✗ systemd-timesyncd 服务启动失败。\033[0m"; log "timesyncd启动失败"; return 1; fi
    return 0
}

enable_bbr() {
   log "运行 BBR 启用程序"
   echo -e "\033[36m▶ 检查并开启 BBR...\033[0m"; local kv rv ccc cq; kv=$(uname -r|cut -d- -f1); rv="4.9"; if ! printf '%s\n' "$rv" "$kv" | sort -V -C; then echo "内核($kv)过低"; log "BBR失败:内核低"; return 1; fi; echo "内核 $kv 支持BBR"; ccc=$(sysctl net.ipv4.tcp_congestion_control|awk '{print $3}'); cq=$(sysctl net.core.default_qdisc|awk '{print $3}'); echo "当前拥塞控制:$ccc"; echo "当前队列调度:$cq"; if [[ "$ccc" == "bbr" && "$cq" == "fq" ]]; then echo "BBR+FQ已启用"; fi; echo "应用sysctl...";
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
   return 0
}

toolbox_menu() {
   while true; do
       clear_cmd
       local colors=("\033[31m" "\033[38;5;208m" "\033[33m" "\033[32m" "\033[34m" "\033[35m")
       local num_colors=${#colors[@]}; local color_index=0
       local logo_lines=(
"    ███████╗ ██████╗ ██████╗ ██╗     ███████╗ ██████╗ ██╗  ██╗"
"    ██╔════╝██╔════╝██╔════╝ ██║     ██╔════╝██╔════╝ ╚██╗██╔╝"
"    ███████╗██║     ██║  ███╗██║     ███████╗██║  ███╗ ╚███╔╝ "
"    ╚════██║██║     ██║   ██║██║     ╚════██║██║   ██║ ██╔██╗ "
"    ███████║╚██████╗╚██████╔╝███████╗███████║╚██████╔╝██╔╝ ██╗"
"    ╚══════╝ ╚═════╝ ╚═════╝ ╚══════╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝"
       ); for line in "${logo_lines[@]}"; do echo -e "${colors[$color_index]}$line\033[0m"; color_index=$(( (color_index + 1) % num_colors )); done
       echo -e "\033[36m v$CURRENT_VERSION - 工具箱\033[0m"
       echo -e "\033[36m"; echo " 1) 📦 Docker 安装/升级"; echo " 2) 🕒 时间同步"; echo " 3) 🚀 BBR+FQ 开启"; echo " 4) 💾 备份工具"; echo " 5) ↩️ 返回主菜单"; echo -e "\033[0m";
       local choice; read -p "请输入选项 (1-5): " choice
       case $choice in
         1) InstallDocker;; 2) SyncTime;; 3) enable_bbr;; 4) backup_menu;; 5) return 0;; *) echo "无效选项";;
       esac
       read -p "按回车继续..."
   done
}
