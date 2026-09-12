#!/bin/bash
# v2node sing-box 内核专用安装命令
# 用法: bash install-singbox.sh [版本号] [--api-host URL] [--node-id ID] [--api-key KEY]
export V2NODE_INSTALL_KERNEL=singbox
exec bash <(curl -Ls "https://raw.githubusercontent.com/LOVEYIKANUOSI/v2node-release/main/install.sh?t=$(date +%s)") "$@"