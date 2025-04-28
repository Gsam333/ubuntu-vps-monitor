#!/bin/bash
# VPS监控脚本 - 本地版

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

# 默认配置
INSTALL_DIR="/opt/vps-monitor"
SERVICE_NAME="vps-monitor"
CONFIG_FILE="$INSTALL_DIR/config.conf"
DATA_DIR="$INSTALL_DIR/data"
HISTORY_LENGTH=1440  # 保存24小时的数据（每分钟一条）

# 显示横幅
show_banner() {
    clear
    echo -e "${BLUE}┌─────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│       ${GREEN}VPS监控系统 - 本地版${BLUE}                │${NC}"
    echo -e "${BLUE}│                                             │${NC}"
    echo -e "${BLUE}│  ${YELLOW}功能: 监控CPU、内存、硬盘和网络使用情况${BLUE}    │${NC}"
    echo -e "${BLUE}│  ${YELLOW}版本: 1.0.0                            ${BLUE}   │${NC}"
    echo -e "${BLUE}└─────────────────────────────────────────────┘${NC}"
    echo ""
}

# 检查是否为root用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 此脚本需要root权限${NC}"
        exit 1
    fi
}

# 加载配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

# 保存配置
save_config() {
    mkdir -p "$INSTALL_DIR"
    cat > "$CONFIG_FILE" << EOF
# VPS监控系统配置文件
INSTALL_DIR="$INSTALL_DIR"
SERVICE_NAME="$SERVICE_NAME"
DATA_DIR="$DATA_DIR"
HISTORY_LENGTH="$HISTORY_LENGTH"
EOF
    chmod 600 "$CONFIG_FILE"
}

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}正在检查并安装依赖...${NC}"
    
    # 检测包管理器
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt-get"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    else
        echo -e "${RED}不支持的系统，无法自动安装依赖${NC}"
        return 1
    fi
    
    # 安装依赖
    $PKG_MANAGER update -y
    $PKG_MANAGER install -y bc curl ifstat jq
    
    echo -e "${GREEN}依赖安装完成${NC}"
    return 0
}

# 创建监控脚本
create_monitor_script() {
    echo -e "${YELLOW}正在创建监控脚本...${NC}"
    
    cat > "$INSTALL_DIR/monitor.sh" << 'EOF'
#!/bin/bash

# 配置
INSTALL_DIR="__INSTALL_DIR__"
DATA_DIR="__DATA_DIR__"
HISTORY_LENGTH="__HISTORY_LENGTH__"
INTERVAL=60  # 监控间隔（秒）
LOG_FILE="/var/log/vps-monitor.log"
CURRENT_DATA_FILE="$DATA_DIR/current.json"
HISTORY_DATA_FILE="$DATA_DIR/history.json"

# 确保数据目录存在
mkdir -p "$DATA_DIR"

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 获取CPU使用率
get_cpu_usage() {
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\\([0-9.]*\\)%* id.*/\\1/" | awk '{print 100 - $1}')
    cpu_load=$(cat /proc/loadavg | awk '{print $1","$2","$3}')
    echo "{\"usage_percent\":$cpu_usage,\"load_avg\":[$cpu_load]}"
}

# 获取内存使用情况
get_memory_usage() {
    total=$(free -k | grep Mem | awk '{print $2}')
    used=$(free -k | grep Mem | awk '{print $3}')
    free=$(free -k | grep Mem | awk '{print $4}')
    usage_percent=$(echo "scale=1; $used * 100 / $total" | bc)
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# 获取硬盘使用情况
get_disk_usage() {
    disk_info=$(df -k / | tail -1)
    total=$(echo "$disk_info" | awk '{print $2 / 1024 / 1024}')
    used=$(echo "$disk_info" | awk '{print $3 / 1024 / 1024}')
    free=$(echo "$disk_info" | awk '{print $4 / 1024 / 1024}')
    usage_percent=$(echo "$disk_info" | awk '{print $5}' | tr -d '%')
    echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"usage_percent\":$usage_percent}"
}

# 获取网络使用情况
get_network_usage() {
    # 检查是否安装了ifstat
    if ! command -v ifstat &> /dev/null; then
        log "ifstat未安装，无法获取网络速度"
        echo "{\"upload_speed\":0,\"download_speed\":0,\"total_upload\":0,\"total_download\":0}"
        return
    fi
    
    # 获取网络接口
    interface=$(ip route | grep default | awk '{print $5}')
    
    # 获取网络速度（KB/s）
    network_speed=$(ifstat -i "$interface" 1 1 | tail -1)
    download_speed=$(echo "$network_speed" | awk '{print $1 * 1024}')
    upload_speed=$(echo "$network_speed" | awk '{print $2 * 1024}')
    
    # 获取总流量
    rx_bytes=$(cat /proc/net/dev | grep "$interface" | awk '{print $2}')
    tx_bytes=$(cat /proc/net/dev | grep "$interface" | awk '{print $10}')
    
    echo "{\"upload_speed\":$upload_speed,\"download_speed\":$download_speed,\"total_upload\":$tx_bytes,\"total_download\":$rx_bytes}"
}

# 保存数据到历史文件
save_to_history() {
    local data="$1"
    local timestamp=$(date +%s)
    
    # 创建包含时间戳的条目
    local entry="{\"timestamp\":$timestamp,\"data\":$data}"
    
    # 如果历史文件不存在，创建新的
    if [ ! -f "$HISTORY_DATA_FILE" ]; then
        echo "[$entry]" > "$HISTORY_DATA_FILE"
        return
    fi
    
    # 读取现有历史数据
    local history=$(cat "$HISTORY_DATA_FILE")
    
    # 删除开头的 [ 和结尾的 ]
    history=$(echo "$history" | sed 's/^\[//;s/\]$//')
    
    # 添加新条目
    history="[$entry,$history]"
    
    # 限制历史长度
    history=$(echo "$history" | jq ".[0:$HISTORY_LENGTH]")
    
    # 保存回文件
    echo "$history" > "$HISTORY_DATA_FILE"
}

# 收集并保存监控数据
collect_metrics() {
    timestamp=$(date +%s)
    cpu=$(get_cpu_usage)
    memory=$(get_memory_usage)
    disk=$(get_disk_usage)
    network=$(get_network_usage)
    
    data="{\"timestamp\":$timestamp,\"cpu\":$cpu,\"memory\":$memory,\"disk\":$disk,\"network\":$network}"
    
    # 保存当前数据
    echo "$data" > "$CURRENT_DATA_FILE"
    
    # 添加到历史数据
    save_to_history "$data"
    
    log "数据收集完成"
}

# 主函数
main() {
    log "VPS本地监控脚本启动"
    
    # 创建日志文件
    touch "$LOG_FILE"
    
    # 主循环
    while true; do
        collect_metrics
        sleep $INTERVAL
    done
}

# 启动主函数
main
EOF

    # 替换配置
    sed -i "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$INSTALL_DIR/monitor.sh"
    sed -i "s|__DATA_DIR__|$DATA_DIR|g" "$INSTALL_DIR/monitor.sh"
    sed -i "s|__HISTORY_LENGTH__|$HISTORY_LENGTH|g" "$INSTALL_DIR/monitor.sh"

    # 创建查看脚本
    cat > "$INSTALL_DIR/view-stats.sh" << 'EOF'
#!/bin/bash

# 配置
INSTALL_DIR="__INSTALL_DIR__"
DATA_DIR="__DATA_DIR__"
CURRENT_DATA_FILE="$DATA_DIR/current.json"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

# 显示横幅
show_banner() {
    clear
    echo -e "${BLUE}┌─────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│       ${GREEN}VPS监控系统 - 实时状态${BLUE}              │${NC}"
    echo -e "${BLUE}└─────────────────────────────────────────────┘${NC}"
    echo ""
}

# 格式化字节大小
format_bytes() {
    local bytes=$1
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes}B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$(echo "scale=2; $bytes/1024" | bc)KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$(echo "scale=2; $bytes/1048576" | bc)MB"
    else
        echo "$(echo "scale=2; $bytes/1073741824" | bc)GB"
    fi
}

# 检查文件是否存在
if [ ! -f "$CURRENT_DATA_FILE" ]; then
    echo -e "${RED}错误: 监控数据文件不存在，请确保监控服务正在运行${NC}"
    exit 1
fi

# 读取当前数据
data=$(cat "$CURRENT_DATA_FILE")

# 解析数据
timestamp=$(echo "$data" | jq -r '.timestamp')
date_time=$(date -d @"$timestamp" '+%Y-%m-%d %H:%M:%S')

cpu_usage=$(echo "$data" | jq -r '.cpu.usage_percent')
cpu_load1=$(echo "$data" | jq -r '.cpu.load_avg[0]')
cpu_load5=$(echo "$data" | jq -r '.cpu.load_avg[1]')
cpu_load15=$(echo "$data" | jq -r '.cpu.load_avg[2]')

mem_total=$(echo "$data" | jq -r '.memory.total')
mem_used=$(echo "$data" | jq -r '.memory.used')
mem_free=$(echo "$data" | jq -r '.memory.free')
mem_usage=$(echo "$data" | jq -r '.memory.usage_percent')

disk_total=$(echo "$data" | jq -r '.disk.total')
disk_used=$(echo "$data" | jq -r '.disk.used')
disk_free=$(echo "$data" | jq -r '.disk.free')
disk_usage=$(echo "$data" | jq -r '.disk.usage_percent')

net_up_speed=$(echo "$data" | jq -r '.network.upload_speed')
net_down_speed=$(echo "$data" | jq -r '.network.download_speed')
net_total_up=$(echo "$data" | jq -r '.network.total_upload')
net_total_down=$(echo "$data" | jq -r '.network.total_download')

# 格式化输出
show_banner
echo -e "${CYAN}更新时间: ${YELLOW}$date_time${NC}"
echo ""

echo -e "${CYAN}CPU 状态:${NC}"
echo -e "  使用率: ${YELLOW}${cpu_usage}%${NC}"
echo -e "  负载: ${YELLOW}${cpu_load1} (1分钟), ${cpu_load5} (5分钟), ${cpu_load15} (15分钟)${NC}"
echo ""

echo -e "${CYAN}内存状态:${NC}"
mem_total_mb=$(echo "scale=0; $mem_total/1024" | bc)
mem_used_mb=$(echo "scale=0; $mem_used/1024" | bc)
mem_free_mb=$(echo "scale=0; $mem_free/1024" | bc)
echo -e "  总内存: ${YELLOW}${mem_total_mb} MB${NC}"
echo -e "  已使用: ${YELLOW}${mem_used_mb} MB (${mem_usage}%)${NC}"
echo -e "  空闲: ${YELLOW}${mem_free_mb} MB${NC}"
echo ""

echo -e "${CYAN}硬盘状态:${NC}"
echo -e "  总空间: ${YELLOW}${disk_total} GB${NC}"
echo -e "  已使用: ${YELLOW}${disk_used} GB (${disk_usage}%)${NC}"
echo -e "  空闲: ${YELLOW}${disk_free} GB${NC}"
echo ""

echo -e "${CYAN}网络状态:${NC}"
formatted_up_speed=$(format_bytes "$net_up_speed")
formatted_down_speed=$(format_bytes "$net_down_speed")
formatted_total_up=$(format_bytes "$net_total_up")
formatted_total_down=$(format_bytes "$net_total_down")

echo -e "  上传速度: ${YELLOW}${formatted_up_speed}/s${NC}"
echo -e "  下载速度: ${YELLOW}${formatted_down_speed}/s${NC}"
echo -e "  总上传: ${YELLOW}${formatted_total_up}${NC}"
echo -e "  总下载: ${YELLOW}${formatted_total_down}${NC}"
echo ""

echo -e "${CYAN}监控服务状态: ${GREEN}运行中${NC}"
EOF

    # 创建实时监控脚本
    cat > "$INSTALL_DIR/live-monitor.sh" << 'EOF'
#!/bin/bash

# 配置
INSTALL_DIR="__INSTALL_DIR__"
DATA_DIR="__DATA_DIR__"
REFRESH_INTERVAL=2  # 刷新间隔（秒）

# 执行查看脚本
while true; do
    $INSTALL_DIR/view-stats.sh
    echo ""
    echo -e "自动刷新中... 按 Ctrl+C 退出"
    sleep $REFRESH_INTERVAL
done
EOF

    # 替换配置
    sed -i "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$INSTALL_DIR/view-stats.sh"
    sed -i "s|__DATA_DIR__|$DATA_DIR|g" "$INSTALL_DIR/view-stats.sh"
    sed -i "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$INSTALL_DIR/live-monitor.sh"
    sed -i "s|__DATA_DIR__|$DATA_DIR|g" "$INSTALL_DIR/live-monitor.sh"

    # 设置执行权限
    chmod +x "$INSTALL_DIR/monitor.sh"
    chmod +x "$INSTALL_DIR/view-stats.sh"
    chmod +x "$INSTALL_DIR/live-monitor.sh"
    
    echo -e "${GREEN}监控脚本创建完成${NC}"
}

# 创建systemd服务
create_service() {
    echo -e "${YELLOW}正在创建系统服务...${NC}"
    
    cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=VPS Local Monitor Service
After=network.target

[Service]
ExecStart=$INSTALL_DIR/monitor.sh
Restart=always
User=root
Group=root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    
    echo -e "${GREEN}系统服务创建完成${NC}"
}

# 安装监控系统
install_monitor() {
    show_banner
    echo -e "${CYAN}开始安装本地VPS监控系统...${NC}"
    
    # 检查是否已安装
    if systemctl is-active --quiet $SERVICE_NAME; then
        echo -e "${YELLOW}监控系统已经安装并运行中。${NC}"
        echo -e "${YELLOW}如需重新安装，请先卸载现有安装。${NC}"
        return
    fi
    
    # 创建安装目录
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR"
    
    # 安装依赖
    install_dependencies || {
        echo -e "${RED}安装依赖失败，请手动安装bc、curl、ifstat和jq${NC}"
        return 1
    }
    
    # 创建监控脚本
    create_monitor_script
    
    # 创建systemd服务
    create_service
    
    # 保存配置
    save_config
    
    # 启动服务
    echo -e "${YELLOW}正在启动监控服务...${NC}"
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    
    echo -e "${GREEN}本地VPS监控系统安装完成！${NC}"
    echo -e "${CYAN}服务状态: $(systemctl is-active $SERVICE_NAME)${NC}"
    echo -e "${CYAN}查看当前状态：$INSTALL_DIR/view-stats.sh${NC}"
    echo -e "${CYAN}实时监控：$INSTALL_DIR/live-monitor.sh${NC}"
    echo -e "${CYAN}查看服务状态: systemctl status $SERVICE_NAME${NC}"
    echo -e "${CYAN}查看服务日志: journalctl -u $SERVICE_NAME -f${NC}"
    echo -e "${CYAN}或: tail -f /var/log/vps-monitor.log${NC}"
    
    # 创建快捷命令
    ln -sf "$INSTALL_DIR/view-stats.sh" /usr/local/bin/vps-stats
    ln -sf "$INSTALL_DIR/live-monitor.sh" /usr/local/bin/vps-monitor
    chmod +x /usr/local/bin/vps-stats
    chmod +x /usr/local/bin/vps-monitor
    
    echo -e "${GREEN}已创建快捷命令:${NC}"
    echo -e "  ${YELLOW}vps-stats${NC} - 查看当前系统状态"
    echo -e "  ${YELLOW}vps-monitor${NC} - 进入实时监控模式"
}

# 卸载监控系统
uninstall_monitor() {
    show_banner
    echo -e "${CYAN}开始卸载本地VPS监控系统...${NC}"
    
    # 检查是否已安装
    if ! systemctl is-active --quiet $SERVICE_NAME && [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}监控系统未安装。${NC}"
        return
    fi
    
    # 确认卸载
    read -p "确定要卸载本地VPS监控系统吗？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo -e "${YELLOW}卸载已取消。${NC}"
        return
    fi
    
    # 停止并禁用服务
    echo -e "${YELLOW}正在停止监控服务...${NC}"
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    
    # 删除服务文件
    echo -e "${YELLOW}正在删除系统服务...${NC}"
    rm -f "/etc/systemd/system/$SERVICE_NAME.service"
    systemctl daemon-reload
    
    # 删除安装目录
    echo -e "${YELLOW}正在删除安装文件...${NC}"
    rm -rf "$INSTALL_DIR"
    
    # 删除快捷命令
    rm -f /usr/local/bin/vps-stats
    rm -f /usr/local/bin/vps-monitor
    
    echo -e "${GREEN}本地VPS监控系统已成功卸载！${NC}"
}

# 查看监控状态
check_status() {
    show_banner
    
    # 检查服务状态
    if systemctl is-active --quiet $SERVICE_NAME; then
        "$INSTALL_DIR/view-stats.sh"
    else
        echo -e "${RED}监控服务未运行，无法显示状态${NC}"
        echo -e "${YELLOW}尝试启动服务: systemctl start $SERVICE_NAME${NC}"
    fi
}

# 查看监控日志
view_logs() {
    show_banner
    echo -e "${CYAN}VPS监控系统日志:${NC}"
    
    if [ -f "/var/log/vps-monitor.log" ]; then
        echo -e "${YELLOW}显示最近50行日志，按Ctrl+C退出${NC}"
        echo ""
        tail -n 50 -f "/var/log/vps-monitor.log"
    else
        echo -e "${RED}日志文件不存在${NC}"
        echo -e "${YELLOW}尝试查看系统日志:${NC}"
        journalctl -u "$SERVICE_NAME" -n 50 --no-pager
    fi
}

# 重启监控服务
restart_service() {
    show_banner
    echo -e "${CYAN}正在重启VPS监控服务...${NC}"
    
    if systemctl is-active --quiet $SERVICE_NAME; then
        systemctl restart "$SERVICE_NAME"
        echo -e "${GREEN}服务已重启${NC}"
    else
        systemctl start "$SERVICE_NAME"
        echo -e "${GREEN}服务已启动${NC}"
    fi
    
    echo -e "${CYAN}服务状态: $(systemctl is-active $SERVICE_NAME)${NC}"
}

# 实时监控
live_monitor() {
    "$INSTALL_DIR/live-monitor.sh"
}

# 主菜单
show_menu() {
    while true; do
        show_banner
        echo -e "${CYAN}请选择操作:${NC}"
        echo -e "  ${GREEN}1.${NC} 安装监控系统"
        echo -e "  ${GREEN}2.${NC} 卸载监控系统"
        echo -e "  ${GREEN}3.${NC} 查看当前状态"
        echo -e "  ${GREEN}4.${NC} 实时监控"
        echo -e "  ${GREEN}5.${NC} 查看监控日志"
        echo -e "  ${GREEN}6.${NC} 重启监控服务"
        echo -e "  ${GREEN}0.${NC} 退出"
        echo ""
        read -p "请输入选项 [0-6]: " choice
        
        case $choice in
            1) install_monitor ;;
            2) uninstall_monitor ;;
            3) check_status ;;
            4) live_monitor ;;
            5) view_logs ;;
            6) restart_service ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效的选择，请重试${NC}" ;;
        esac
        
        if [ "$choice" != "4" ]; then
            echo ""
            read -p "按Enter键继续..."
        fi
    done
}

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -i, --install        直接安装，不显示菜单"
    echo "  -d, --dir DIR        安装目录 (默认: /opt/vps-monitor)"
    echo "  -h, --help           显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                   显示交互式菜单"
    echo "  $0 -i                直接安装监控系统"
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dir)
                INSTALL_DIR="$2"
                DATA_DIR="$INSTALL_DIR/data"
                shift 2
                ;;
            -i|--install)
                DIRECT_INSTALL=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo -e "${RED}未知参数: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
}

# 主函数
main() {
    check_root
    
    # 加载现有配置
    load_config
    
    # 解析命令行参数
    parse_args "$@"
    
    # 直接安装或显示菜单
    if [ "$DIRECT_INSTALL" = "1" ]; then
        install_monitor
    else
        show_menu
    fi
}

# 执行主函数
main "$@"
