#!/bin/bash
# 一键安装脚本 for server-optimization-scripts v1.3 (仅模块化版本)

VERSION="v1.3"
URL="https://github.com/cristsau/server-optimization-scripts/releases/download/$VERSION/server-optimization-scripts-$VERSION.tar.gz"
INSTALL_DIR="/root/server-optimization-scripts"

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请以 root 用户运行此脚本"
    exit 1
fi

# 安装依赖
apt-get update && apt-get install -y curl || { echo "错误: 安装 curl 失败"; exit 1; }

# 创建安装目录
mkdir -p "$INSTALL_DIR" || { echo "错误: 创建目录 $INSTALL_DIR 失败"; exit 1; }
cd "$INSTALL_DIR" || exit 1

# 下载并解压
curl -sSL "$URL" -o "server-optimization-scripts-$VERSION.tar.gz" || { echo "错误: 下载失败"; exit 1; }
tar -xzf "server-optimization-scripts-$VERSION.tar.gz" || { echo "错误: 解压失败"; exit 1; }
rm -f "server-optimization-scripts-$VERSION.tar.gz"

# 进入模块化目录并执行安装
cd modular_optimizer || { echo "错误: 目录 modular_optimizer 不存在"; exit 1; }
chmod +x setup_optimize_server.sh
./setup_optimize_server.sh || { echo "错误: 执行 setup_optimize_server.sh 失败"; exit 1; }

echo "安装完成！运行 '/root/server-optimization-scripts/modular_optimizer/setup_optimize_server.sh' 查看菜单。"