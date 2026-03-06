#!/bin/sh
# OpenVPN客户端证书生成和配置文件生成脚本
# 参考genovpn.sh的原理，但不修改原文件

# 读取openvpn-admin配置
if [ -f /etc/config/openvpn-admin ]; then
    # 从配置文件中读取相关路径
    EASYRSA_DIR=$(uci -q get openvpn-admin.@settings[0].easyrsa_dir 2>/dev/null || echo "/etc/easy-rsa")
    EASYRSA_PKI=$(uci -q get openvpn-admin.@settings[0].easyrsa_pki 2>/dev/null || echo "/etc/easy-rsa/pki")
    OPENVPN_PKI=$(uci -q get openvpn-admin.@settings[0].openvpn_pki 2>/dev/null || echo "/etc/openvpn/pki")
    OPENVPN_INSTANCE=$(uci -q get openvpn-admin.@settings[0].openvpn_instance 2>/dev/null || echo "myvpn")
else
    # 默认值
    EASYRSA_DIR="/etc/easy-rsa"
    EASYRSA_PKI="$EASYRSA_DIR/pki"
    OPENVPN_PKI="/etc/openvpn/pki"
    OPENVPN_INSTANCE="myvpn"
fi

EASYRSA_VARS="$EASYRSA_DIR/vars-server"
TEMP_DIR="/tmp/openvpn-client"

# 参数检查
if [ -z "$1" ]; then
    echo "错误: 请指定客户端名称"
    exit 1
fi

CLIENT_NAME="$1"
OUTPUT_FILE="${2:-/tmp/$CLIENT_NAME.ovpn}"

# 创建临时目录
mkdir -p "$TEMP_DIR"

# 获取服务器配置 - 使用配置中的实例名称
DDNS=$(uci get openvpn.$OPENVPN_INSTANCE.ddns 2>/dev/null || echo "")
PORT=$(uci get openvpn.$OPENVPN_INSTANCE.port 2>/dev/null || echo "1194")
PROTO=$(uci get openvpn.$OPENVPN_INSTANCE.proto 2>/dev/null || echo "udp")

# 如果获取不到DDNS，尝试获取WAN IP
if [ -z "$DDNS" ] || [ "$DDNS" = "exmple.com" ]; then
    DDNS=$(uci get network.wan.ipaddr 2>/dev/null || echo "")
    if [ -z "$DDNS" ]; then
        DDNS=$(ip addr show br-lan 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
    fi
fi

# 检查证书是否存在
check_client_cert() {
    local client_name="$1"
    
    # 检查是否已存在客户端证书
    if [ -f "$EASYRSA_PKI/issued/$client_name.crt" ] && \
       [ -f "$EASYRSA_PKI/private/$client_name.key" ]; then
        echo "客户端证书已存在: $client_name"
        return 0
    fi
    
    echo "客户端证书不存在: $client_name"
    return 1
}

# 生成客户端证书
generate_client_cert() {
    local client_name="$1"
    
    echo "正在生成客户端证书: $client_name"
    
    # 设置环境变量
    export EASYRSA_PKI="$EASYRSA_PKI"
    export EASYRSA_VARS_FILE="$EASYRSA_VARS"
    export EASYRSA_BATCH="1"
    
    # 切换到EasyRSA目录
    cd "$EASYRSA_DIR" || exit 1
    
    # 生成客户端证书（非交互模式）
    echo "正在生成证书..."
    if ! easyrsa build-client-full "$client_name" nopass >/dev/null 2>&1; then
        # 如果失败，尝试初始化PKI
        echo "初始化PKI并生成证书..."
        easyrsa init-pki
        easyrsa build-ca nopass
        easyrsa build-client-full "$client_name" nopass
    fi
    
    # 复制证书到OpenVPN目录
    mkdir -p "$OPENVPN_PKI"
    cp "$EASYRSA_PKI/ca.crt" "$OPENVPN_PKI/"
    cp "$EASYRSA_PKI/issued/$client_name.crt" "$OPENVPN_PKI/"
    cp "$EASYRSA_PKI/private/$client_name.key" "$OPENVPN_PKI/"
    
    echo "客户端证书生成完成: $client_name"
}

# 提取纯PEM格式证书（关键修复）
extract_pem_cert() {
    local cert_file="$1"
    
    if [ ! -f "$cert_file" ]; then
        echo "# 证书文件不存在"
        return 1
    fi
    
    # 提取BEGIN CERTIFICATE到END CERTIFICATE之间的内容
    # 使用sed提取纯PEM格式
    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$cert_file"
}

# 提取纯PEM格式密钥
extract_pem_key() {
    local key_file="$1"
    
    if [ ! -f "$key_file" ]; then
        echo "# 密钥文件不存在"
        return 1
    fi
    
    # 提取BEGIN PRIVATE KEY到END PRIVATE KEY之间的内容
    sed -n '/-----BEGIN.*PRIVATE KEY-----/,/-----END.*PRIVATE KEY-----/p' "$key_file"
}

# 生成.ovpn配置文件（修复后）
generate_ovpn_config() {
    local client_name="$1"
    local output_file="$2"
    
    echo "正在生成配置文件: $output_file"
    
    # 创建配置文件
    cat > "$output_file" <<EOF
##############################################
# OpenVPN 客户端配置文件
# 生成时间: $(date)
# 客户端: $CLIENT_NAME
# 服务器: $DDNS:$PORT
##############################################

client
dev tun
proto $PROTO
remote $DDNS $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
verb 3

# 加密设置
cipher AES-256-GCM
auth SHA256

# TLS设置
remote-cert-tls server
key-direction 1

EOF

    # 添加CA证书 - 使用纯PEM格式
    echo "<ca>" >> "$output_file"
    if [ -f "$OPENVPN_PKI/ca.crt" ]; then
        extract_pem_cert "$OPENVPN_PKI/ca.crt" >> "$output_file"
    elif [ -f "$EASYRSA_PKI/ca.crt" ]; then
        extract_pem_cert "$EASYRSA_PKI/ca.crt" >> "$output_file"
    else
        echo "# CA证书不存在" >> "$output_file"
    fi
    echo "</ca>" >> "$output_file"

    # 添加客户端证书 - 使用纯PEM格式（关键修复）
    echo "<cert>" >> "$output_file"
    if [ -f "$OPENVPN_PKI/$client_name.crt" ]; then
        extract_pem_cert "$OPENVPN_PKI/$client_name.crt" >> "$output_file"
    elif [ -f "$EASYRSA_PKI/issued/$client_name.crt" ]; then
        extract_pem_cert "$EASYRSA_PKI/issued/$client_name.crt" >> "$output_file"
    else
        echo "# 客户端证书不存在" >> "$output_file"
    fi
    echo "</cert>" >> "$output_file"

    # 添加客户端密钥 - 使用纯PEM格式
    echo "<key>" >> "$output_file"
    if [ -f "$OPENVPN_PKI/$client_name.key" ]; then
        extract_pem_key "$OPENVPN_PKI/$client_name.key" >> "$output_file"
    elif [ -f "$EASYRSA_PKI/private/$client_name.key" ]; then
        extract_pem_key "$EASYRSA_PKI/private/$client_name.key" >> "$output_file"
    else
        echo "# 客户端密钥不存在" >> "$output_file"
    fi
    echo "</key>" >> "$output_file"

    # 添加附加配置（如果存在）
    if [ -f "/etc/openvpn-addon.conf" ]; then
        cat "/etc/openvpn-addon.conf" >> "$output_file"
    fi
    
    echo "配置文件生成完成: $output_file"
}

# 主执行流程
main() {
    echo "开始生成OpenVPN客户端配置"
    echo "客户端名称: $CLIENT_NAME"
    echo "输出文件: $OUTPUT_FILE"
    echo "服务器地址: $DDNS:$PORT ($PROTO)"
    echo "使用实例: $OPENVPN_INSTANCE"
    echo "EasyRSA目录: $EASYRSA_DIR"
    echo "PKI目录: $EASYRSA_PKI"
    
    # 检查证书是否存在
    if ! check_client_cert "$CLIENT_NAME"; then
        echo "证书不存在，开始生成..."
        if ! generate_client_cert "$CLIENT_NAME"; then
            echo "错误: 证书生成失败"
            exit 1
        fi
    fi
    
    # 生成.ovpn配置文件
    generate_ovpn_config "$CLIENT_NAME" "$OUTPUT_FILE"
    
    # 验证文件是否生成成功
    if [ -f "$OUTPUT_FILE" ]; then
        echo "生成成功！"
        echo "文件位置: $OUTPUT_FILE"
        echo "文件大小: $(du -h "$OUTPUT_FILE" | cut -f1)"
    else
        echo "错误: 文件生成失败"
        exit 1
    fi
}

# 执行主函数
main