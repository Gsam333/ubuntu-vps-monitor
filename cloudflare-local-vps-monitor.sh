#!/bin/bash
# VPS监控脚本 - 本地版 + Cloudflare Worker版

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

# API 配置
API_ENABLED=false
API_PORT=8787
API_KEY=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)  # 随机生成的API密钥
API_ALLOW_IPS="127.0.0.1"  # 默认只允许本地访问，多个IP用逗号分隔

# Cloudflare Worker配置
CF_WORKER_ENABLED=false
CF_WORKER_URL=""
CF_WORKER_NAME="vps-monitor"

# 显示横幅
show_banner() {
    clear
    echo -e "${BLUE}┌─────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│       ${GREEN}VPS监控系统 - 增强版${BLUE}                │${NC}"
    echo -e "${BLUE}│                                             │${NC}"
    echo -e "${BLUE}│  ${YELLOW}功能: 监控CPU、内存、硬盘和网络使用情况${BLUE}    │${NC}"
    echo -e "${BLUE}│  ${YELLOW}版本: 2.0.0                            ${BLUE}   │${NC}"
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

# API配置
API_ENABLED=$API_ENABLED
API_PORT=$API_PORT
API_KEY="$API_KEY"
API_ALLOW_IPS="$API_ALLOW_IPS"

# Cloudflare Worker配置
CF_WORKER_ENABLED=$CF_WORKER_ENABLED
CF_WORKER_URL="$CF_WORKER_URL"
CF_WORKER_NAME="$CF_WORKER_NAME"
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
    $PKG_MANAGER install -y bc curl ifstat jq socat
    
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

# API 配置
API_ENABLED=__API_ENABLED__
API_PORT=__API_PORT__
API_KEY="__API_KEY__"
API_ALLOW_IPS="__API_ALLOW_IPS__"

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
    }
    
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

# 获取系统基本信息
get_system_info() {
    hostname=$(hostname)
    kernel=$(uname -r)
    os=$(cat /etc/os-release | grep "PRETTY_NAME" | cut -d= -f2- | tr -d '"')
    uptime=$(uptime -p)
    ip_addr=$(hostname -I | awk '{print $1}')
    
    echo "{\"hostname\":\"$hostname\",\"kernel\":\"$kernel\",\"os\":\"$os\",\"uptime\":\"$uptime\",\"ip\":\"$ip_addr\"}"
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
    system_info=$(get_system_info)
    cpu=$(get_cpu_usage)
    memory=$(get_memory_usage)
    disk=$(get_disk_usage)
    network=$(get_network_usage)
    
    data="{\"timestamp\":$timestamp,\"system\":$system_info,\"cpu\":$cpu,\"memory\":$memory,\"disk\":$disk,\"network\":$network}"
    
    # 保存当前数据
    echo "$data" > "$CURRENT_DATA_FILE"
    
    # 添加到历史数据
    save_to_history "$data"
    
    log "数据收集完成"
}

# 启动API服务器的函数
run_api_server() {
    # 如果API未启用，则不运行
    if [ "$API_ENABLED" != "true" ]; then
        return
    fi
    
    log "启动API服务器在端口 $API_PORT"
    
    # 使用socat作为简单的API服务器
    while true; do
        socat -v TCP-LISTEN:$API_PORT,reuseaddr,fork EXEC:"$INSTALL_DIR/api-handler.sh" 2>> "$LOG_FILE" &
        
        # 记录API服务器的PID
        API_SERVER_PID=$!
        log "API服务进程启动，PID: $API_SERVER_PID"
        
        # 等待API服务器进程结束
        wait $API_SERVER_PID
        
        # 如果服务终止，尝试重启
        log "API服务已终止，正在重启..."
        sleep 5
    done &
}

# 创建API处理脚本
create_api_handler() {
    cat > "$INSTALL_DIR/api-handler.sh" << 'EOF'
#!/bin/bash

# 读取配置
INSTALL_DIR="__INSTALL_DIR__"
DATA_DIR="__DATA_DIR__"
API_KEY="__API_KEY__"
API_ALLOW_IPS="__API_ALLOW_IPS__"
CURRENT_DATA_FILE="$DATA_DIR/current.json"
HISTORY_DATA_FILE="$DATA_DIR/history.json"
LOG_FILE="/var/log/vps-monitor.log"

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - API: $1" >> "$LOG_FILE"
}

# 解析请求
read -r request

# 记录请求
log "收到请求: $request"

# 提取请求方法和路径
method=$(echo "$request" | cut -d' ' -f1)
path=$(echo "$request" | cut -d' ' -f2)

# 读取所有请求头
declare -A headers
while read -r line; do
    line=$(echo "$line" | tr -d '\r\n')
    if [ -z "$line" ]; then
        break
    fi
    key=$(echo "$line" | cut -d':' -f1 | tr 'A-Z' 'a-z')
    value=$(echo "$line" | cut -d':' -f2- | sed 's/^ //g')
    headers["$key"]="$value"
done

# 获取客户端IP (在某些情况下可能不准确)
client_ip=${headers["x-forwarded-for"]:-${headers["x-real-ip"]:-"unknown"}}

# 获取API密钥
auth_header=${headers["authorization"]:-""}
provided_key=$(echo "$auth_header" | sed 's/Bearer //')

# 检查IP和API密钥
ip_allowed=false
IFS=',' read -ra ALLOWED_IPS <<< "$API_ALLOW_IPS"
for ip in "${ALLOWED_IPS[@]}"; do
    if [[ "$client_ip" == "$ip" || "$ip" == "*" ]]; then
        ip_allowed=true
        break
    fi
done

# 函数：发送HTTP响应
send_response() {
    local status="$1"
    local content_type="$2"
    local body="$3"
    
    echo -e "HTTP/1.1 $status\r"
    echo -e "Content-Type: $content_type\r"
    echo -e "Access-Control-Allow-Origin: *\r"
    echo -e "Access-Control-Allow-Methods: GET, OPTIONS\r"
    echo -e "Access-Control-Allow-Headers: Authorization, Content-Type\r"
    echo -e "Content-Length: ${#body}\r"
    echo -e "\r"
    echo -n "$body"
}

# 处理OPTIONS请求 (CORS预检)
if [ "$method" = "OPTIONS" ]; then
    send_response "200 OK" "text/plain" ""
    exit 0
fi

# 检查认证
if [ "$provided_key" != "$API_KEY" ] && [ "$ip_allowed" != "true" ]; then
    log "认证失败或IP不允许: $client_ip, 密钥: $provided_key"
    send_response "403 Forbidden" "application/json" '{"error":"未授权访问"}'
    exit 0
fi

# 根据路径处理请求
if [ "$path" = "/api/current" ]; then
    if [ -f "$CURRENT_DATA_FILE" ]; then
        data=$(cat "$CURRENT_DATA_FILE")
        send_response "200 OK" "application/json" "$data"
    else
        send_response "404 Not Found" "application/json" '{"error":"数据不可用"}'
    fi
elif [ "$path" = "/api/history" ]; then
    if [ -f "$HISTORY_DATA_FILE" ]; then
        data=$(cat "$HISTORY_DATA_FILE")
        send_response "200 OK" "application/json" "$data"
    else
        send_response "404 Not Found" "application/json" '{"error":"历史数据不可用"}'
    fi
elif [ "$path" = "/api/status" ]; then
    # 简单的状态检查
    send_response "200 OK" "application/json" '{"status":"running","version":"2.0.0"}'
else
    send_response "404 Not Found" "application/json" '{"error":"未找到请求的资源"}'
fi
EOF

    # 替换配置
    sed -i "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$INSTALL_DIR/api-handler.sh"
    sed -i "s|__DATA_DIR__|$DATA_DIR|g" "$INSTALL_DIR/api-handler.sh"
    sed -i "s|__API_KEY__|$API_KEY|g" "$INSTALL_DIR/api-handler.sh"
    sed -i "s|__API_ALLOW_IPS__|$API_ALLOW_IPS|g" "$INSTALL_DIR/api-handler.sh"
    
    # 设置执行权限
    chmod +x "$INSTALL_DIR/api-handler.sh"
}

# 主函数
main() {
    log "VPS监控脚本启动"
    
    # 创建日志文件
    touch "$LOG_FILE"
    
    # 如果API启用，创建API处理程序并启动API服务器
    if [ "$API_ENABLED" = "true" ]; then
        create_api_handler
        run_api_server
    fi
    
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
    sed -i "s|__API_ENABLED__|$API_ENABLED|g" "$INSTALL_DIR/monitor.sh"
    sed -i "s|__API_PORT__|$API_PORT|g" "$INSTALL_DIR/monitor.sh"
    sed -i "s|__API_KEY__|$API_KEY|g" "$INSTALL_DIR/monitor.sh"
    sed -i "s|__API_ALLOW_IPS__|$API_ALLOW_IPS|g" "$INSTALL_DIR/monitor.sh"

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

# 系统信息
hostname=$(echo "$data" | jq -r '.system.hostname')
os=$(echo "$data" | jq -r '.system.os')
uptime=$(echo "$data" | jq -r '.system.uptime')
ip=$(echo "$data" | jq -r '.system.ip')

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
echo -e "${CYAN}系统信息:${NC}"
echo -e "  主机名: ${YELLOW}$hostname${NC}"
echo -e "  系统: ${YELLOW}$os${NC}"
echo -e "  运行时间: ${YELLOW}$uptime${NC}"
echo -e "  IP地址: ${YELLOW}$ip${NC}"
echo ""

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

# 显示API信息
if [ -f "$INSTALL_DIR/config.conf" ]; then
    source "$INSTALL_DIR/config.conf"
    if [ "$API_ENABLED" = "true" ]; then
        echo ""
        echo -e "${CYAN}API状态:${NC}"
        echo -e "  状态: ${GREEN}启用${NC}"
        echo -e "  端口: ${YELLOW}$API_PORT${NC}"
        echo -e "  密钥: ${YELLOW}$API_KEY${NC}"
        
        if [ "$CF_WORKER_ENABLED" = "true" ]; then
            echo ""
            echo -e "${CYAN}Cloudflare Worker:${NC}"
            echo -e "  状态: ${GREEN}已配置${NC}"
            echo -e "  地址: ${YELLOW}$CF_WORKER_URL${NC}"
        fi
    fi
fi
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

    # 创建Cloudflare Worker脚本
    cat > "$INSTALL_DIR/cloudflare-worker.js" << 'EOF'
// VPS监控系统 - Cloudflare Worker
const SERVER_URL = '__SERVER_URL__';
const API_KEY = '__API_KEY__';

// 定义HTML模板
const HTML_TEMPLATE = `
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VPS监控系统</title>
    <style>
        :root {
            --primary-color: #3498db;
            --secondary-color: #2ecc71;
            --warning-color: #f39c12;
            --danger-color: #e74c3c;
            --text-color: #2c3e50;
            --bg-color: #f8f9fa;
            --card-bg: #ffffff;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 0;
            padding: 0;
            background-color: var(--bg-color);
            color: var(--text-color);
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        
        .header {
            text-align: center;
            margin-bottom: 30px;
            border-bottom: 2px solid var(--primary-color);
            padding-bottom: 10px;
        }
        
        .header h1 {
            color: var(--primary-color);
            margin-bottom: 5px;
        }
        
        .system-info {
            display: flex;
            flex-wrap: wrap;
            justify-content: space-between;
            margin-bottom: 20px;
        }
        
        .info-item {
            background-color: var(--card-bg);
            padding: 10px 15px;
            border-radius: 5px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
            margin-bottom: 10px;
            flex: 1;
            min-width: 200px;
            margin-right: 10px;
        }
        
        .info-item:last-child {
            margin-right: 0;
        }
        
        .info-item h3 {
            margin-top: 0;
            color: var(--primary-color);
            border-bottom: 1px solid #eee;
            padding-bottom: 5px;
        }
        
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        
        .card {
            background-color: var(--card-bg);
            border-radius: 8px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            padding: 20px;
            transition: transform 0.3s ease;
        }
        
        .card:hover {
            transform: translateY(-5px);
        }
        
        .card h2 {
            margin-top: 0;
            color: var(--primary-color);
            border-bottom: 1px solid #eee;
            padding-bottom: 10px;
        }
        
        .stat {
            display: flex;
            justify-content: space-between;
            margin-bottom: 10px;
        }
.stat .label {
            font-weight: 500;
            color: var(--text-color);
        }
        
        .stat .value {
            font-weight: 600;
            color: var(--primary-color);
        }
        
        .progress-bar {
            height: 10px;
            width: 100%;
            background-color: #ecf0f1;
            border-radius: 5px;
            margin: 5px 0 15px;
            overflow: hidden;
        }
        
        .progress {
            height: 100%;
            border-radius: 5px;
            transition: width 0.3s ease;
        }
        
        .progress.low {
            background-color: var(--secondary-color);
        }
        
        .progress.medium {
            background-color: var(--warning-color);
        }
        
        .progress.high {
            background-color: var(--danger-color);
        }
        
        .footer {
            text-align: center;
            font-size: 0.9rem;
            margin-top: 30px;
            padding-top: 15px;
            border-top: 1px solid #ddd;
            color: #7f8c8d;
        }
        
        .update-time {
            text-align: right;
            font-size: 0.9rem;
            color: #7f8c8d;
            margin-bottom: 20px;
        }
        
        .refresh-btn {
            background-color: var(--primary-color);
            color: white;
            border: none;
            padding: 10px 15px;
            border-radius: 5px;
            cursor: pointer;
            font-weight: 500;
            transition: background-color 0.3s ease;
            display: block;
            margin: 20px auto;
        }
        
        .refresh-btn:hover {
            background-color: #2980b9;
        }
        
        @media (max-width: 768px) {
            .grid {
                grid-template-columns: 1fr;
            }
            
            .system-info {
                flex-direction: column;
            }
            
            .info-item {
                margin-right: 0;
                margin-bottom: 10px;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>VPS监控系统</h1>
            <p>实时服务器状态监控</p>
        </div>
        
        <div class="update-time" id="update-time"></div>
        
        <div class="system-info" id="system-info">
            <!-- 系统信息将被动态填充 -->
        </div>
        
        <div class="grid">
            <div class="card">
                <h2>CPU状态</h2>
                <div class="stat">
                    <div class="label">使用率</div>
                    <div class="value" id="cpu-usage">--</div>
                </div>
                <div class="progress-bar">
                    <div class="progress low" id="cpu-progress" style="width: 0%"></div>
                </div>
                <div class="stat">
                    <div class="label">负载 (1分钟)</div>
                    <div class="value" id="cpu-load1">--</div>
                </div>
                <div class="stat">
                    <div class="label">负载 (5分钟)</div>
                    <div class="value" id="cpu-load5">--</div>
                </div>
                <div class="stat">
                    <div class="label">负载 (15分钟)</div>
                    <div class="value" id="cpu-load15">--</div>
                </div>
            </div>
            
            <div class="card">
                <h2>内存状态</h2>
                <div class="stat">
                    <div class="label">使用率</div>
                    <div class="value" id="mem-usage">--</div>
                </div>
                <div class="progress-bar">
                    <div class="progress low" id="mem-progress" style="width: 0%"></div>
                </div>
                <div class="stat">
                    <div class="label">总内存</div>
                    <div class="value" id="mem-total">--</div>
                </div>
                <div class="stat">
                    <div class="label">已使用</div>
                    <div class="value" id="mem-used">--</div>
                </div>
                <div class="stat">
                    <div class="label">空闲</div>
                    <div class="value" id="mem-free">--</div>
                </div>
            </div>
            
            <div class="card">
                <h2>硬盘状态</h2>
                <div class="stat">
                    <div class="label">使用率</div>
                    <div class="value" id="disk-usage">--</div>
                </div>
                <div class="progress-bar">
                    <div class="progress low" id="disk-progress" style="width: 0%"></div>
                </div>
                <div class="stat">
                    <div class="label">总空间</div>
                    <div class="value" id="disk-total">--</div>
                </div>
                <div class="stat">
                    <div class="label">已使用</div>
                    <div class="value" id="disk-used">--</div>
                </div>
                <div class="stat">
                    <div class="label">空闲</div>
                    <div class="value" id="disk-free">--</div>
                </div>
            </div>
            
            <div class="card">
                <h2>网络状态</h2>
                <div class="stat">
                    <div class="label">上传速度</div>
                    <div class="value" id="net-up-speed">--</div>
                </div>
                <div class="stat">
                    <div class="label">下载速度</div>
                    <div class="value" id="net-down-speed">--</div>
                </div>
                <div class="stat">
                    <div class="label">总上传</div>
                    <div class="value" id="net-total-up">--</div>
                </div>
                <div class="stat">
                    <div class="label">总下载</div>
                    <div class="value" id="net-total-down">--</div>
                </div>
            </div>
        </div>
        
        <button class="refresh-btn" onclick="fetchData()">刷新数据</button>
        
        <div class="footer">
            <p>VPS监控系统 - Cloudflare Worker版 | &copy; 2025</p>
        </div>
    </div>
    
    <script>
        // 格式化字节大小
        function formatBytes(bytes) {
            if (bytes === 0) return '0 B';
            
            const k = 1024;
            const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }
        
        // 格式化时间戳
        function formatTimestamp(timestamp) {
            const date = new Date(timestamp * 1000);
            return date.toLocaleString();
        }
        
        // 设置进度条颜色
        function setProgressColor(element, value) {
            element.classList.remove('low', 'medium', 'high');
            
            if (value < 50) {
                element.classList.add('low');
            } else if (value < 80) {
                element.classList.add('medium');
            } else {
                element.classList.add('high');
            }
        }
        
        // 提取系统信息
        function updateSystemInfo(data) {
            const sysInfo = data.system;
            const container = document.getElementById('system-info');
            container.innerHTML = '';
            
            const items = [
                { label: '主机名', value: sysInfo.hostname },
                { label: '系统', value: sysInfo.os },
                { label: '运行时间', value: sysInfo.uptime },
                { label: 'IP地址', value: sysInfo.ip }
            ];
            
            items.forEach(item => {
                const div = document.createElement('div');
                div.className = 'info-item';
                div.innerHTML = `
                    <h3>${item.label}</h3>
                    <div>${item.value}</div>
                `;
                container.appendChild(div);
            });
        }
        
        // 更新数据
        function updateData(data) {
            // 更新时间
            document.getElementById('update-time').textContent = '最后更新: ' + formatTimestamp(data.timestamp);
            
            // 更新系统信息
            updateSystemInfo(data);
            
            // 更新CPU信息
            const cpuUsage = data.cpu.usage_percent.toFixed(1);
            document.getElementById('cpu-usage').textContent = cpuUsage + '%';
            document.getElementById('cpu-load1').textContent = data.cpu.load_avg[0];
            document.getElementById('cpu-load5').textContent = data.cpu.load_avg[1];
            document.getElementById('cpu-load15').textContent = data.cpu.load_avg[2];
            
            const cpuProgress = document.getElementById('cpu-progress');
            cpuProgress.style.width = cpuUsage + '%';
            setProgressColor(cpuProgress, cpuUsage);
            
            // 更新内存信息
            const memTotal = Math.round(data.memory.total / 1024);
            const memUsed = Math.round(data.memory.used / 1024);
            const memFree = Math.round(data.memory.free / 1024);
            const memUsage = data.memory.usage_percent;
            
            document.getElementById('mem-usage').textContent = memUsage + '%';
            document.getElementById('mem-total').textContent = memTotal + ' MB';
            document.getElementById('mem-used').textContent = memUsed + ' MB';
            document.getElementById('mem-free').textContent = memFree + ' MB';
            
            const memProgress = document.getElementById('mem-progress');
            memProgress.style.width = memUsage + '%';
            setProgressColor(memProgress, memUsage);
            
            // 更新硬盘信息
            const diskTotal = data.disk.total.toFixed(1);
            const diskUsed = data.disk.used.toFixed(1);
            const diskFree = data.disk.free.toFixed(1);
            const diskUsage = data.disk.usage_percent;
            
            document.getElementById('disk-usage').textContent = diskUsage + '%';
            document.getElementById('disk-total').textContent = diskTotal + ' GB';
            document.getElementById('disk-used').textContent = diskUsed + ' GB';
            document.getElementById('disk-free').textContent = diskFree + ' GB';
            
            const diskProgress = document.getElementById('disk-progress');
            diskProgress.style.width = diskUsage + '%';
            setProgressColor(diskProgress, diskUsage);
            
            // 更新网络信息
            document.getElementById('net-up-speed').textContent = formatBytes(data.network.upload_speed) + '/s';
            document.getElementById('net-down-speed').textContent = formatBytes(data.network.download_speed) + '/s';
            document.getElementById('net-total-up').textContent = formatBytes(data.network.total_upload);
            document.getElementById('net-total-down').textContent = formatBytes(data.network.total_download);
        }
        
        // 获取数据
        async function fetchData() {
            try {
                const response = await fetch('/api/current');
                if (!response.ok) {
                    throw new Error('无法获取监控数据');
                }
                
                const data = await response.json();
                updateData(data);
            } catch (error) {
                console.error('获取数据错误:', error);
                document.getElementById('update-time').textContent = '获取数据失败: ' + error.message;
            }
        }
        
        // 页面加载时获取数据
        document.addEventListener('DOMContentLoaded', () => {
            fetchData();
            // 每30秒自动刷新
            setInterval(fetchData, 30000);
        });
    </script>
</body>
</html>
`;

// 处理请求的主函数
async function handleRequest(request) {
  const url = new URL(request.url);
  const path = url.pathname;
  
  // API端点 - 获取当前状态
  if (path === '/api/current') {
    return await fetchServerData('current');
  }
  
  // API端点 - 获取历史数据
  if (path === '/api/history') {
    return await fetchServerData('history');
  }
  
  // 主页面 - 返回HTML
  return new Response(HTML_TEMPLATE, {
    headers: {
      'Content-Type': 'text/html; charset=UTF-8',
    },
  });
}

// 从服务器获取数据
async function fetchServerData(endpoint) {
  try {
    const response = await fetch(`${SERVER_URL}/api/${endpoint}`, {
      headers: {
        'Authorization': `Bearer ${API_KEY}`,
      },
    });
    
    if (!response.ok) {
      throw new Error(`服务器返回错误: ${response.status}`);
    }
    
    const data = await response.json();
    
    return new Response(JSON.stringify(data), {
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
      },
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
      },
    });
  }
}

// 注册Fetch事件处理器
addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request));
});
EOF

    # 创建Cloudflare Worker部署指导
    cat > "$INSTALL_DIR/cloudflare-setup.md" << 'EOF'
# Cloudflare Worker 部署指南

本指南将帮助您在Cloudflare上部署Worker来显示VPS监控信息。

## 前提条件

1. 一个 Cloudflare 账户
2. 您需要在Cloudflare上注册一个域名，或使用Cloudflare提供的`workers.dev`子域名

## 步骤1：启用API服务

确保您的VPS监控系统API服务已启用：

```bash
sudo vps-setup --api-enable --api-port=8787
```

如果需要，配置API密钥和允许的IP：

```bash
sudo vps-setup --api-key="您的密钥" --api-allow-ips="*"
```

## 步骤2：确保API端点可外部访问

- 如果您的服务器有防火墙，请确保API端口已开放
- 确保有正确的公网IP或域名指向您的服务器

## 步骤3：部署Cloudflare Worker

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. 进入 Workers & Pages 部分
3. 点击 "Create application"
4. 选择 "Create Worker"
5. 给您的worker取一个名称，如 `vps-monitor`
6. 在编辑界面中，删除默认代码，并粘贴 `cloudflare-worker.js` 的内容
7. 在文件顶部更新以下变量：
   - `SERVER_URL`: 您服务器的URL，如 `http://your-server-ip:8787`
   - `API_KEY`: 您为API配置的密钥

## 步骤4：配置自定义域名 (可选)

1. 在Worker的设置中，选择 "Triggers" 标签页
2. 在 "Routes" 部分添加自定义路由，例如：`monitor.yourdomain.com/*`
3. 保存配置

## 步骤5：访问监控

现在您可以通过以下URL访问您的监控系统：
- 使用workers.dev域名: `https://your-worker-name.your-subdomain.workers.dev`
- 或者您配置的自定义域名: `https://monitor.yourdomain.com`

## 故障排除

如果遇到问题，请检查：

1. API服务是否正常运行：`systemctl status vps-monitor`
2. API端口是否可访问：`curl http://localhost:8787/api/status`
3. 检查防火墙设置：`sudo ufw status` 或 `sudo iptables -L`
4. 检查Cloudflare Worker日志，在Cloudflare Dashboard中查看

对于更多帮助，请参考 [Cloudflare Workers文档](https://developers.cloudflare.com/workers/)
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

# 配置API
configure_api() {
    show_banner
    echo -e "${CYAN}配置API功能${NC}"
    
    echo -e "API服务允许通过HTTP访问监控数据，这对于Cloudflare Worker功能是必需的。"
    echo ""
    
    read -p "启用API服务? (y/n): " enable_api
    if [ "$enable_api" = "y" ] || [ "$enable_api" = "Y" ]; then
        API_ENABLED=true
        
        # 配置API端口
        read -p "请输入API服务端口 [默认: 8787]: " api_port
        if [ -n "$api_port" ]; then
            API_PORT=$api_port
        fi
        
        # 配置API密钥
        read -p "是否生成新的API密钥? (y/n) [默认: y]: " new_key
        if [ "$new_key" != "n" ] && [ "$new_key" != "N" ]; then
            API_KEY=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
            echo -e "${GREEN}已生成新的API密钥${NC}"
        else
            read -p "请输入自定义API密钥: " custom_key
            if [ -n "$custom_key" ]; then
                API_KEY=$custom_key
            fi
        fi
        
        # 配置允许的IP
        read -p "请输入允许访问API的IP地址 (用逗号分隔, 使用*允许所有IP) [默认: 127.0.0.1]: " allowed_ips
        if [ -n "$allowed_ips" ]; then
            API_ALLOW_IPS=$allowed_ips
        fi
        
        echo -e "${GREEN}API配置完成${NC}"
    else
        API_ENABLED=false
        echo -e "${YELLOW}API服务已禁用${NC}"
    fi
    
    # 保存配置
    save_config
}

# 配置Cloudflare Worker
configure_cf_worker() {
    show_banner
    echo -e "${CYAN}配置Cloudflare Worker${NC}"
    
    # 检查API是否启用
    if [ "$API_ENABLED" != "true" ]; then
        echo -e "${RED}错误: 必须先启用API功能才能配置Cloudflare Worker${NC}"
        echo -e "${YELLOW}请先运行: ${NC}configure_api"
        return 1
    fi
    
    echo -e "此功能将帮助您配置Cloudflare Worker以远程访问VPS监控。"
    echo -e "您需要一个Cloudflare账户并了解如何部署Workers。"
    echo ""
    
    read -p "配置Cloudflare Worker? (y/n): " enable_worker
    if [ "$enable_worker" = "y" ] || [ "$enable_worker" = "Y" ]; then
        CF_WORKER_ENABLED=true
        
        # 获取服务器URL
        echo -e "${YELLOW}请输入您服务器的公网URL(包括协议和端口)${NC}"
        echo -e "例如: http://your-server-ip:$API_PORT 或 https://your-domain.com:$API_PORT"
        read -p "服务器URL: " server_url
        
        # 获取Worker URL
        read -p "Cloudflare Worker URL (例如: https://vps-monitor.your-subdomain.workers.dev): " worker_url
        CF_WORKER_URL=$worker_url
        
        # 替换Worker脚本中的变量
        sed -i "s|__SERVER_URL__|$server_url|g" "$INSTALL_DIR/cloudflare-worker.js"
        sed -i "s|__API_KEY__|$API_KEY|g" "$INSTALL_DIR/cloudflare-worker.js"
        
        echo -e "${GREEN}Cloudflare Worker配置文件已准备就绪${NC}"
        echo -e "${CYAN}Worker脚本路径: ${YELLOW}$INSTALL_DIR/cloudflare-worker.js${NC}"
        echo -e "${CYAN}部署指南路径: ${YELLOW}$INSTALL_DIR/cloudflare-setup.md${NC}"
        echo ""
        echo -e "${YELLOW}请按照部署指南将Worker部署到Cloudflare${NC}"
    else
        CF_WORKER_ENABLED=false
        echo -e "${YELLOW}Cloudflare Worker功能已禁用${NC}"
    fi
    
    # 保存配置
    save_config
}

# 安装监控系统
install_monitor() {
    show_banner
    echo -e "${CYAN}开始安装VPS监控系统...${NC}"
    
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
        echo -e "${RED}安装依赖失败，请手动安装bc、curl、ifstat、jq和socat${NC}"
        return 1
    }
    
    # 创建监控脚本
    create_monitor_script
    
    # 创建systemd服务
    create_service
    
    # 配置API
    configure_api
    
    # 如果API已启用，询问是否配置Cloudflare Worker
    if [ "$API_ENABLED" = "true" ]; then
        read -p "是否希望配置Cloudflare Worker来远程访问监控? (y/n): " configure_worker
        if [ "$configure_worker" = "y" ] || [ "$configure_worker" = "Y" ]; then
            configure_cf_worker
        fi
    fi
    
    # 保存配置
    save_config
    
    # 启动服务
    echo -e "${YELLOW}正在启动监控服务...${NC}"
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    
    echo -e "${GREEN}VPS监控系统安装完成！${NC}"
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
    
    # 创建配置命令
    cat > /usr/local/bin/vps-setup << EOF
#!/bin/bash
$INSTALL_DIR/setup.sh "\$@"
EOF
    chmod +x /usr/local/bin/vps-setup
    
    echo -e "${GREEN}已创建快捷命令:${NC}"
    echo -e "  ${YELLOW}vps-stats${NC} - 查看当前系统状态"
    echo -e "  ${YELLOW}vps-monitor${NC} - 进入实时监控模式"
    echo -e "  ${YELLOW}vps-setup${NC} - 配置监控系统"
    
    # 如果已配置Cloudflare Worker，显示相关信息
    if [ "$CF_WORKER_ENABLED" = "true" ]; then
        echo ""
        echo -e "${CYAN}Cloudflare Worker 信息:${NC}"
        echo -e "  ${YELLOW}Worker URL: $CF_WORKER_URL${NC}"
        echo -e "  ${YELLOW}Worker 脚本: $INSTALL_DIR/cloudflare-worker.js${NC}"
        echo -e "  ${YELLOW}部署指南: $INSTALL_DIR/cloudflare-setup.md${NC}"
    fi
}

# 卸载监控系统
uninstall_monitor() {
    show_banner
    echo -e "${CYAN}开始卸载VPS监控系统...${NC}"
    
    # 检查是否已安装
    if ! systemctl is-active --quiet $SERVICE_NAME && [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}监控系统未安装。${NC}"
        return
    fi
    
    # 确认卸载
    read -p "确定要卸载VPS监控系统吗？(y/n): " confirm
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
    rm -f /usr/local/bin/vps-setup
    
    echo -e "${GREEN}VPS监控系统已成功卸载！${NC}"
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
        echo -e "${RED}日志文件不存在${NC