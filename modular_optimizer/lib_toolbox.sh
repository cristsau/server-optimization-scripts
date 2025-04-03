#!/bin/bash
# lib_toolbox.sh - Toolbox functions (v1.3.1 - Ensure compatibility and traffic monitor menu)

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
source "$SCRIPT_DIR/lib_utils.sh" # For log, clear_cmd, check_command, get_ssh_port
source "$SCRIPT_DIR/lib_backup.sh" # For backup_menu
source "$SCRIPT_DIR/lib_traffic_config.sh" # For traffic_monitor_config_menu

# --- Functions ---
check_service_status() { 
    local service_name="$1" display_name="$2"; 
    local status="Unknown" status_color="\033[33m" status_icon="❓"; 
    printf "  %-20s: " "$display_name"; 
    if command -v systemctl >/dev/null; then 
        if systemctl is-active --quiet "$service_name"; then 
            status="Active/Running"; status_color="\033[32m"; status_icon="✅"; 
        elif systemctl status "$service_name" >/dev/null 2>&1; then 
            status="Inactive/Stopped"; status_color="\033[33m"; status_icon="⚠️"; 
        else 
            status="Not Found/Error"; status_color="\033[31m"; status_icon="❌"; 
        fi; 
    else 
        status="Cannot check"; 
    fi; 
    echo -e "${status_icon} ${status_color}${status}\033[0m"; 
    log "Health Check - $display_name: $status"; 
}

check_network() { 
    local target_host="8.8.8.8" target_host6="2001:4860:4860::8888"; 
    local status status_color status_icon; 
    printf "  %-20s: " "Network (IPv4 DNS)"; 
    if ping -c 1 -W 1 "$target_host" > /dev/null 2>&1; then 
        status="OK"; status_color="\033[32m"; status_icon="✅"; 
        echo -e "${status_icon} ${status_color}${status}\033[0m"; 
        log "Network IPv4 OK"; 
    else 
        status="Failed"; status_color="\033[31m"; status_icon="❌"; 
        echo -e "${status_icon} ${status_color}${status}\033[0m"; 
        log "Network IPv4 Failed"; 
    fi; 
    if ip -6 route get "$target_host6" >/dev/null 2>&1; then 
        printf "  %-20s: " "Network (IPv6 DNS)"; 
        if ping -6 -c 1 -W 1 "$target_host6" > /dev/null 2>&1; then 
            status="OK"; status_color="\033[32m"; status_icon="✅"; 
            echo -e "${status_icon} ${status_color}${status}\033[0m"; 
            log "Network IPv6 OK"; 
        else 
            status="Failed"; status_color="\033[31m"; status_icon="❌"; 
            echo -e "${status_icon} ${status_color}${status}\033[0m"; 
            log "Network IPv6 Failed"; 
        fi; 
    else 
        log "IPv6 skip"; 
    fi; 
}

run_health_check() { 
    log "运行健康检查"; 
    echo -e "\n\033[1;36m🔬 执行基本健康检查...\033[0m"; 
    check_command "ping" || return 1; 
    check_command "ip" || return 1; 
    echo -e "\n  \033[1m核心服务状态:\033[0m"; 
    check_service_status "cron" "Cron Daemon"; 
    if command -v docker >/dev/null 2>&1; then 
        check_service_status "docker" "Docker Daemon"; 
    else 
        printf "  %-20s: %s\n" "Docker Daemon" "ℹ️ 未安装"; 
        log "Docker Not Installed"; 
    fi; 
    echo -e "\n  \033[1m网络连通性:\033[0m"; 
    check_network; 
    echo -e "\n\033[32m✔ 健康检查完成。\033[0m"; 
    log "健康检查完成"; 
    return 0; 
}

InstallDocker() { 
    log "运行 Docker 安装/升级程序"; 
    echo -e "\033[36m▶ 检查并安装/升级 Docker...\033[0m"; 
    check_command "curl" || return 1; 
    local docker_installed=false current_version=""; 
    if command -v docker >/dev/null 2>&1; then 
        current_version=$(docker --version 2>/dev/null | awk '{print $3}' | sed 's/,//'); 
        if [ -n "$current_version" ]; then 
            echo "当前 Docker 版本: $current_version"; 
            docker_installed=true; 
        else 
            echo -e "\033[33m警告:无法获取 Docker 版本号\033[0m"; 
        fi; 
    else 
        echo "未检测到 Docker。"; 
    fi; 
    read -p "运行官方脚本安装/升级 Docker？(y/N): " install_docker; 
    if [[ "$install_docker" == "y" || "$install_docker" == "Y" ]]; then 
        echo "运行 get.docker.com..."; 
        curl -fsSL https://get.docker.com | sh; 
        if [ $? -eq 0 ]; then 
            echo -e "\033[32m✔ Docker 安装/升级脚本执行成功。\033[0m"; 
            log "Docker 安装/升级成功"; 
            if command -v systemctl > /dev/null; then 
                echo "尝试启动 Docker 服务..."; 
                systemctl enable docker > /dev/null 2>&1; 
                systemctl start docker > /dev/null 2>&1; 
                if systemctl is-active --quiet docker; then 
                    echo -e "\033[32m✔ Docker 服务已启动。\033[0m"; 
                else 
                    echo -e "\033[33m⚠ Docker 服务启动失败。\033[0m"; 
                fi; 
            fi; 
        else 
            echo -e "\033[31m✗ Docker 安装/升级脚本执行失败。\033[0m"; 
            log "Docker 安装/升级失败"; 
            return 1; 
        fi; 
    else 
        echo "跳过 Docker 安装/升级。"; 
    fi; 
    return 0; 
}

SyncTime() { 
    log "运行时间同步程序"; 
    echo -e "\033[36m▶ 正在同步服务器时间 (使用 systemd-timesyncd)...\033[0m"; 
    check_command "timedatectl" || return 1; 
    check_command "systemctl" || return 1; 
    check_command "apt-get" || return 1; 
    check_command "dpkg" || return 1; 
    echo "检查 timesyncd 服务状态..."; 
    if ! dpkg -s systemd-timesyncd >/dev/null 2>&1; then 
        echo "未找到 systemd-timesyncd，尝试安装..."; 
        apt-get update -qq && apt-get install -y systemd-timesyncd || { echo "安装失败"; log "安装timesyncd失败"; return 1; }; 
    fi; 
    echo "启用并重启 systemd-timesyncd 服务..."; 
    systemctl enable systemd-timesyncd > /dev/null 2>&1; 
    systemctl restart systemd-timesyncd; 
    sleep 2; 
    if systemctl is-active --quiet systemd-timesyncd; then 
        echo -e "\033[32m✔ systemd-timesyncd 服务运行中。\033[0m"; 
        echo "设置系统时钟使用 NTP 同步..."; 
        timedatectl set-ntp true; 
        if [ $? -eq 0 ]; then 
            echo -e "\033[32m✔ NTP 同步已启用。\033[0m"; 
            log "时间同步配置完成"; 
        else 
            echo -e "\033[31m✗ 启用 NTP 同步失败。\033[0m"; 
            log "启用 NTP 同步失败"; 
        fi; 
        echo "当前时间状态："; 
        timedatectl status; 
    else 
        echo -e "\033[31m✗ systemd-timesyncd 服务启动失败。\033[0m"; 
        log "timesyncd启动失败"; 
        return 1; 
    fi; 
    return 0; 
}

enable_bbr() { 
    log "运行 BBR 启用程序"; 
    echo -e "\033[36m▶ 检查并开启 BBR...\033[0m"; 
    local kv rv ccc cq; 
    kv=$(uname -r|cut -d- -f1); 
    rv="4.9"; 
    if ! printf '%s\n' "$rv" "$kv" | sort -V -C; then 
        echo "内核($kv)过低"; 
        log "BBR失败:内核低"; 
        return 1; 
    fi; 
    echo "内核 $kv 支持BBR"; 
    ccc=$(sysctl net.ipv4.tcp_congestion_control|awk '{print $3}'); 
    cq=$(sysctl net.core.default_qdisc|awk '{print $3}'); 
    echo "拥塞控制:$ccc"; 
    echo "队列调度:$cq"; 
    if [[ "$ccc" == "bbr" && "$cq" == "fq" ]]; then 
        echo "BBR+FQ已启用"; 
    fi; 
    echo "应用sysctl..."; 
    cat > /etc/sysctl.conf <<EOF
# Added by optimize_server script
fs.file-max=6815744
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
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    if [ $? -ne 0 ]; then 
        echo "写入sysctl.conf失败"; 
        log "写入sysctl.conf失败"; 
        return 1; 
    fi; 
    if sysctl -p >/dev/null 2>&1; then 
        echo "sysctl应用成功"; 
        log "sysctl应用成功"; 
        ccc=$(sysctl net.ipv4.tcp_congestion_control|awk '{print $3}'); 
        cq=$(sysctl net.core.default_qdisc|awk '{print $3}'); 
        if [[ "$ccc" == "bbr" && "$cq" == "fq" ]]; then 
            echo "BBR+FQ已启用"; 
            log "BBR+FQ启用成功"; 
        else 
            echo "BBR/FQ未完全启用($ccc, $cq),需重启"; 
            log "BBR/FQ未完全启用"; 
        fi; 
    else 
        echo "应用sysctl失败"; 
        log "应用sysctl失败"; 
        return 1; 
    fi; 
    return 0; 
}

# Toolbox Menu
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
        echo -e "\033[36m"
        echo " 1) 📦 Docker 安装/升级"
        echo " 2) 🕒 时间同步"
        echo " 3) 🚀 BBR+FQ 开启"
        echo " 4) 💾 备份工具"
        echo " 5) ❤️  健康检查"
        echo " 6) 🚦 内置流量监控管理"
        echo " 7) ↩️ 返回主菜单"
        echo -e "\033[0m"
        local choice; read -p "请输入选项 (1-7): " choice
        case $choice in
            1) InstallDocker ;;
            2) SyncTime ;;
            3) enable_bbr ;;
            4) backup_menu ;;
            5) run_health_check ;;
            6) traffic_monitor_config_menu ;;
            7) return 0 ;;
            *) echo "无效选项" ;;
        esac
        read -p "按回车继续..."
    done
}