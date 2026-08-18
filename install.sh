#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)
GITHUB_REPO="${V2NODE_GITHUB_REPO:-LOVEYIKANUOSI/v2node-release}"
GITHUB_BRANCH="${V2NODE_GITHUB_BRANCH:-main}"
RELEASE_REPO="${V2NODE_RELEASE_REPO:-LOVEYIKANUOSI/v2node-release}"
RAW_BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}"
RELEASE_BASE_URL="https://github.com/${RELEASE_REPO}/releases/download"
LATEST_RELEASE_API="https://api.github.com/repos/${RELEASE_REPO}/releases/latest"

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

########################
# 参数解析
########################
VERSION_ARG=""
API_HOST_ARG=""
NODE_ID_ARG=""
API_KEY_ARG=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-host)
                API_HOST_ARG="$2"; shift 2 ;;
            --node-id)
                NODE_ID_ARG="$2"; shift 2 ;;
            --api-key)
                API_KEY_ARG="$2"; shift 2 ;;
            -h|--help)
                echo "用法: $0 [版本号] [--api-host URL] [--node-id ID] [--api-key KEY]"
                exit 0 ;;
            --*)
                echo "未知参数: $1"; exit 1 ;;
            *)
                # 兼容第一个位置参数作为版本号
                if [[ -z "$VERSION_ARG" ]]; then
                    VERSION_ARG="$1"; shift
                else
                    shift
                fi ;;
        esac
    done
}

arch=$(uname -m)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}注意： CentOS 7 无法使用hysteria1/2协议！${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

install_base() {
    # 优化版本：批量检查和安装包，减少系统调用
    need_install_apt() {
        local packages=("$@")
        local missing=()
        
        # 批量检查已安装的包
        local installed_list=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)
        
        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done
        
        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "安装缺失的包: ${missing[*]}"
            apt-get update -y >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1
        fi
    }

    need_install_yum() {
        local packages=("$@")
        local missing=()
        
        # 批量检查已安装的包
        local installed_list=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort)
        
        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done
        
        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "安装缺失的包: ${missing[*]}"
            yum install -y "${missing[@]}" >/dev/null 2>&1
        fi
    }

    need_install_apk() {
        local packages=("$@")
        local missing=()
        
        # 批量检查已安装的包
        local installed_list=$(apk info 2>/dev/null | sort)
        
        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done
        
        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "安装缺失的包: ${missing[*]}"
            apk add --no-cache "${missing[@]}" >/dev/null 2>&1
        fi
    }

    # 一次性安装所有必需的包
    if [[ x"${release}" == x"centos" ]]; then
        # 检查并安装 epel-release
        if ! rpm -q epel-release >/dev/null 2>&1; then
            echo "安装 EPEL 源..."
            yum install -y epel-release >/dev/null 2>&1
        fi
        need_install_yum wget curl unzip tar cronie socat ca-certificates pv
        update-ca-trust force-enable >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"alpine" ]]; then
        need_install_apk wget curl unzip tar socat ca-certificates pv
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"debian" ]]; then
        need_install_apt wget curl unzip tar cron socat ca-certificates pv
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"ubuntu" ]]; then
        need_install_apt wget curl unzip tar cron socat ca-certificates pv
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"arch" ]]; then
        echo "更新包数据库..."
        pacman -Sy --noconfirm >/dev/null 2>&1
        # --needed 会跳过已安装的包，非常高效
        echo "安装必需的包..."
        pacman -S --noconfirm --needed wget curl unzip tar cronie socat ca-certificates pv >/dev/null 2>&1
    fi
}

install_management_script() {
    local script_url="${RAW_BASE_URL}/script/v2node.sh"

    # 某些服务器对 /usr/bin 设置了不可变属性，需要临时移除
    local bin_immutable=false
    if lsattr -d /usr/bin/ 2>/dev/null | grep -q '^----i'; then
        bin_immutable=true
        chattr -i /usr/bin/ 2>/dev/null
    fi

    if ! curl -fLsS -o /usr/bin/v2node "${script_url}"; then
        if ! wget -qO /usr/bin/v2node "${script_url}"; then
            echo -e "${red}下载管理脚本失败，请检查服务器是否可以访问 GitHub Raw${plain}"
            exit 1
        fi
    fi

    # Guard against CRLF line endings so Linux can execute the script directly.
    sed -i 's/\r$//' /usr/bin/v2node
    chmod +x /usr/bin/v2node

    # 恢复不可变属性
    if [[ "$bin_immutable" == true ]]; then
        chattr +i /usr/bin/ 2>/dev/null
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /usr/local/v2node/v2node ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service v2node status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl status v2node | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

generate_v2node_config() {
        local api_host="$1"
        local node_id="$2"
        local api_key="$3"

        mkdir -p /etc/v2node >/dev/null 2>&1
        cat > /etc/v2node/config.json <<EOF
{
    "Log": {
        "Level": "warning",
        "Output": "",
        "Access": "none"
    },
    "Nodes": [
        {
            "ApiHost": "${api_host}",
            "NodeID": ${node_id},
            "ApiKey": "${api_key}",
            "Timeout": 15,
            "GlobalSpeedLimitMbps": 0
        }
    ]
}
EOF
        echo -e "${green}V2node 配置文件生成完成,正在重新启动服务${plain}"
        if [[ x"${release}" == x"alpine" ]]; then
            service v2node restart
        else
            systemctl restart v2node
        fi
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}v2node 重启成功${plain}"
        else
            echo -e "${red}v2node 可能启动失败，请使用 v2node log 查看日志信息${plain}"
        fi
}

install_v2node() {
    local version_param="$1"
    if [[ -e /usr/local/v2node/ ]]; then
        rm -rf /usr/local/v2node/
    fi

    mkdir /usr/local/v2node/ -p
    cd /usr/local/v2node/

    download_with_progress() {
        local url="$1"
        local output="$2"
        if command -v pv &>/dev/null; then
            curl -sL "$url" | pv -s 30M -W -N "下载进度" > "$output"
        else
            echo -e "${yellow}pv 未安装，使用普通下载...${plain}"
            curl -sL -o "$output" "$url" --progress-bar
            echo ""
        fi
    }

    if  [[ -z "$version_param" ]] ; then
        last_version=$(curl -Ls "${LATEST_RELEASE_API}" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}从 ${RELEASE_REPO} 获取 release 版本失败，请先发布 release 后再安装${plain}"
            exit 1
        else
            echo -e "${green}检测到 ${RELEASE_REPO} 最新版本：${last_version}，开始安装...${plain}"
            url="${RELEASE_BASE_URL}/${last_version}/v2node-linux-${arch}.zip"
            download_with_progress "$url" /usr/local/v2node/v2node-linux.zip
            if [[ $? -ne 0 ]]; then
                echo -e "${red}从 ${RELEASE_REPO} 下载 release 包失败，请检查 release 资产是否存在${plain}"
                exit 1
            fi
        fi
    else
        last_version=$version_param
        url="${RELEASE_BASE_URL}/${last_version}/v2node-linux-${arch}.zip"
        download_with_progress "$url" /usr/local/v2node/v2node-linux.zip
        if [[ $? -ne 0 ]]; then
            echo -e "${red}从 ${RELEASE_REPO} 下载 v2node $1 失败，请确认该 release 是否存在${plain}"
            exit 1
        fi
    fi

    if [[ -f /usr/local/v2node/v2node-linux.zip ]]; then
        unzip v2node-linux.zip
        rm v2node-linux.zip -f
        chmod +x v2node
        mkdir /etc/v2node/ -p
        cp geoip.dat /etc/v2node/
        cp geosite.dat /etc/v2node/
    fi
    # 某些服务器对 systemd 目录设置了不可变属性，需要临时移除
    local systemd_immutable=false
    if lsattr -d /etc/systemd/system/ 2>/dev/null | grep -q '^----i'; then
        systemd_immutable=true
        find /etc/systemd/system/ -maxdepth 1 -type d -exec chattr -i {} \; 2>/dev/null || true
    fi

    if [[ x"${release}" == x"alpine" ]]; then
        rm /etc/init.d/v2node -f
        cat <<EOF > /etc/init.d/v2node
#!/sbin/openrc-run

name="v2node"
description="v2node"

command="/usr/local/v2node/v2node"
command_args="server"
command_user="root"

pidfile="/run/v2node.pid"
command_background="yes"

depend() {
        need net
}
EOF
        chmod +x /etc/init.d/v2node
        rc-update add v2node default
        echo -e "${green}v2node ${last_version}${plain} 安装完成，已设置开机自启"
    else
        rm /etc/systemd/system/v2node.service -f
        cat <<EOF > /etc/systemd/system/v2node.service
[Unit]
Description=v2node Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/v2node/
ExecStart=/usr/local/v2node/v2node server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl stop v2node 2>/dev/null || true
        systemctl enable v2node
        echo -e "${green}v2node ${last_version}${plain} 安装完成，已设置开机自启"
    fi

    # 恢复不可变属性
    if [[ "$systemd_immutable" == true ]]; then
        find /etc/systemd/system/ -maxdepth 1 -type d -exec chattr +i {} \; 2>/dev/null || true
    fi

    if [[ ! -f /etc/v2node/config.json ]]; then
        # 如果通过 CLI 传入了完整参数，则直接生成配置并跳过交互
        if [[ -n "$API_HOST_ARG" && -n "$NODE_ID_ARG" && -n "$API_KEY_ARG" ]]; then
            generate_v2node_config "$API_HOST_ARG" "$NODE_ID_ARG" "$API_KEY_ARG"
            echo -e "${green}已根据参数生成 /etc/v2node/config.json${plain}"
            first_install=false
        else
            cat > /etc/v2node/config.json <<EOF
{
    "Log": {
        "Level": "warning",
        "Output": "",
        "Access": "none"
    },
    "Nodes": [
        {
            "ApiHost": "https://example.com/",
            "NodeID": 1,
            "ApiKey": "replace-me",
            "Timeout": 15,
            "GlobalSpeedLimitMbps": 0
        }
    ]
}
EOF
            first_install=true
        fi
    else
        # 夺舍/迁移场景：机器上已有旧版（原版）v2node 配置，默认原样继承。
        # 若传入 --api-host/--node-id/--api-key 参数，则只覆盖对应字段（其余字段保留），
        # 用于批量把旧节点的面板地址/节点参数切到新面板，无需逐台 SSH 手改。
        if [[ -n "$API_HOST_ARG" || -n "$NODE_ID_ARG" || -n "$API_KEY_ARG" ]]; then
            echo -e "${yellow}检测到已有 v2node 配置，按传入参数覆盖对应字段（未传字段保持不变）${plain}"
            if command -v python3 >/dev/null 2>&1; then
                python3 - "$API_HOST_ARG" "$NODE_ID_ARG" "$API_KEY_ARG" <<'PYEOF'
import json, sys
api_host, node_id, api_key = sys.argv[1], sys.argv[2], sys.argv[3]
p = "/etc/v2node/config.json"
try:
    cfg = json.load(open(p))
except Exception as e:
    print("读取配置失败:", e)
    sys.exit(1)
nodes = cfg.get("Nodes") or []
if not nodes:
    nodes = [{}]
    cfg["Nodes"] = nodes
if api_host:
    nodes[0]["ApiHost"] = api_host
if node_id:
    nodes[0]["NodeID"] = int(node_id)
if api_key:
    nodes[0]["ApiKey"] = api_key
json.dump(cfg, open(p, "w"), indent=4)
print("已覆盖配置:", json.dumps(nodes[0], ensure_ascii=False))
PYEOF
            else
                echo -e "${red}未找到 python3，无法覆盖已有配置；将原样继承旧配置${plain}"
            fi
        else
            echo -e "${green}检测到已有 v2node 配置，已原样继承（未传覆盖参数）${plain}"
        fi
        if [[ x"${release}" == x"alpine" ]]; then
            service v2node start
        else
            systemctl start v2node
        fi
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}v2node 重启成功${plain}"
        else
            echo -e "${red}v2node 可能启动失败，请使用 v2node log 查看日志信息${plain}"
        fi
        first_install=false
    fi

    install_management_script

    # 创建 v2 快捷命令（交互式面板）
    ln -sf /usr/local/v2node/v2node /usr/bin/v2 2>/dev/null || true

    cd $cur_dir
    rm -f install.sh
    echo "------------------------------------------"
    echo -e "管理脚本使用方法: "
    echo "------------------------------------------"
    echo "v2node              - 显示管理菜单 (功能更多)"
    echo "v2node start        - 启动 v2node"
    echo "v2node stop         - 停止 v2node"
    echo "v2node restart      - 重启 v2node"
    echo "v2node status       - 查看 v2node 状态"
    echo "v2node enable       - 设置 v2node 开机自启"
    echo "v2node disable      - 取消 v2node 开机自启"
    echo "v2node log          - 查看 v2node 日志"
    echo "v2node generate     - 生成 v2node 配置文件"
    echo "v2node update       - 更新 v2node"
    echo "v2node update x.x.x - 更新 v2node 指定版本"
    echo "v2node install      - 安装 v2node"
    echo "v2node uninstall    - 卸载 v2node"
    echo "v2node version      - 查看 v2node 版本"
    echo "------------------------------------------"
    curl -fsS --max-time 10 "https://api.v-50.me/counter" || true

    if [[ $first_install == true ]]; then
        read -rp "检测到你为第一次安装 v2node，是否自动生成 /etc/v2node/config.json？(y/n): " if_generate
        if [[ "$if_generate" =~ ^[Yy]$ ]]; then
            # 交互式收集参数，提供示例默认值
            read -rp "面板API地址[格式: https://example.com/]: " api_host
            api_host=${api_host:-https://example.com/}
            read -rp "节点ID: " node_id
            node_id=${node_id:-1}
            read -rp "节点通讯密钥: " api_key

            # 生成配置文件（覆盖可能从包中复制的模板）
            generate_v2node_config "$api_host" "$node_id" "$api_key"
        else
            echo "${green}已跳过自动生成配置。如需后续生成，可执行: v2node generate${plain}"
        fi
    fi
}

parse_args "$@"
echo -e "${green}开始安装${plain}"
install_base
install_v2node "$VERSION_ARG"
