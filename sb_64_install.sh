#!/bin/sh

red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }

echo "=========================================="
echo "    kkkbox sing-box 64M VPS 安装脚本      "
echo "=========================================="

# 1. 自动创建 128M Swap 防止 64M 小鸡 OOM
swap_size=$(free -m | awk '/Swap/ {print $2}')
if [ "$swap_size" = "0" ]; then
    yellow "检测到无 Swap，正在临时创建 128MB 虚拟内存..."
    dd if=/dev/zero of=/swapfile bs=1M count=128 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile >/dev/null 2>&1
    green "Swap 创建成功！"
fi

# 2. 安装必要依赖 (Alpine使用apk)
echo "正在安装必要依赖..."
apk update >/dev/null 2>&1
apk add wget tar gcompat jq ncdu xxd >/dev/null 2>&1

# 3. 检查并下载 sing-box
if [ ! -f "/root/singbox/sing-box" ]; then
    echo "正在获取 sing-box 最新版本号..."
    last_version=$(wget -qO- https://api.github.com/repos/SagerNet/sing-box/releases | grep -m1 '"tag_name":' | cut -d '"' -f 4)
    [ -z "$last_version" ] && { red "获取版本号失败！"; exit 1; }
    
    file_version=$(echo $last_version | sed 's/^v//')
    
    arch=$(uname -m)
    if [ "$arch" = "x86_64" ] || [ "$arch" = "amd64" ]; then
        box_arch="amd64"
    else
        box_arch="386"
    fi
    
    download_url="https://github.com/SagerNet/sing-box/releases/download/${last_version}/sing-box-${file_version}-linux-${box_arch}.tar.gz"
    yellow "开始下载 sing-box (${box_arch})..."
    wget "$download_url" -O sing-box.tar.gz
    
    mkdir -p /root/singbox
    tar -xzf sing-box.tar.gz
    mv sing-box-${file_version}-linux-${box_arch}/sing-box /root/singbox/
    rm -rf sing-box.tar.gz sing-box-${file_version}-linux-${box_arch}
fi
green "sing-box 文件就绪！"

# 4. 端口选择与检查
read -p "请输入 reality 端口号 [默认: 8443]：" port
[ -z "$port" ] && port=8443

# 5. 生成密钥与UUID
REAL_UUID=$(cat /proc/sys/kernel/random/uuid)
KEYS=$(/root/singbox/sing-box generate reality-keypair)
PRI_KEY=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
PUB_KEY=$(echo "$KEYS" | grep PublicKey | awk '{print $2}')
SHORT_ID=$(dd bs=4 count=2 if=/dev/urandom 2>/dev/null | xxd -p -c 8)
DEST_SERVER="www.microsoft.com"

# 6. 写入完全合法的配置文件
cat << JSON_EOF > /root/singbox/config.json
{
  "log": {
    "disabled": true,
    "level": "fatal"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": $port,
      "users": [
        {
          "uuid": "$REAL_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DEST_SERVER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$DEST_SERVER",
            "server_port": 443
          },
          "private_key": "$PRI_KEY",
          "short_id": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
JSON_EOF

# 7. 获取外网IP并打印客户端连接链接
IP=$(wget -qO- http://ipv4.icanhazip.com || wget -qO- http://ifconfig.me)
SHARE_LINK="vless://${REAL_UUID}@${IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SERVER}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#kkkbox-64M"
echo "$SHARE_LINK" > /root/singbox/share-link.txt

echo "=========================================="
echo "          安装与配置成功完成！            "
echo "=========================================="
green "您的分享链接为："
red "$SHARE_LINK"
echo "------------------------------------------"
yellow "分享链接已自动保存到: /root/singbox/share-link.txt"
echo "=========================================="

# 8. 写入 OpenRC 服务并调优内存墙 (GOGC=20, 限制内存)
cat << 'SVC_EOF' > /etc/init.d/sing-box
#!/sbin/openrc-run
name="sing-box"
command="/root/singbox/sing-box"
command_args="run -c /root/singbox/config.json"
pidfile="/run/sing-box.pid"
command_background="yes"
rc_ulimit="-n 30000"
export GOGC=20
export GOMEMLIMIT=20MiB
depend() { need net; after net; }
SVC_EOF

chmod u+x /etc/init.d/sing-box
rc-update -q add sing-box default
service sing-box restart
service sing-box status
