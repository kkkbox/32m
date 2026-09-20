cat << 'EOF' > sb_install.sh && ash sb_install.sh
#!/bin/sh
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"

red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }

if [ -f "/root/singbox/sing-box" ]; then
    green "sing-box文件已存在！"
else
    echo "正在获取sing-box最新版本号..."
    # 精准抓取最新正式版版本号
    last_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases | grep -m1 '"tag_name":' | cut -d '"' -f 4)
    
    if [ -z "$last_version" ]; then
        red "获取版本号失败，请检查网络或 GitHub API 限制！"
        exit 1
    fi
    
    yellow "sing-box最新版本号为： $last_version"
    echo "开始下载sing-box文件..."
    
    # 针对 i686(32位) 架构下载 linux-386 版本 (去除了开头的 'v' 用于拼接文件名)
    file_version=$(echo $last_version | sed 's/^v//')
    download_url="https://github.com/SagerNet/sing-box/releases/download/${last_version}/sing-box-${file_version}-linux-386.tar.gz"
    
    wget "$download_url" -O sing-box.tar.gz
    
    mkdir -p /root/singbox
    tar -xzf sing-box.tar.gz
    mv sing-box-${file_version}-linux-386/sing-box /root/singbox/
    rm -rf sing-box.tar.gz sing-box-${file_version}-linux-386
    
    if [ -f "/root/singbox/sing-box" ]; then
        green "下载成功！"
    else
        red "下载失败！"
        exit 1
    fi
fi

read -p "请输入reality端口号：" port
sign=false
until $sign; do
    if [ -z "$port" ]; then
        red "错误：端口号不能为空!"
        read -p "请重新输入reality端口号：" port
        continue
    fi
    if ! echo "$port" | grep -qE '^[0-9]+$'; then
        red "错误：端口号必须是数字!"
        read -p "请重新输入reality端口号：" port
        continue
    fi
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        red "错误：端口号必须介于1~65525之间!"
        read -p "请重新输入reality端口号：" port
        continue
    fi
    if [ -z "$(nc -zv 127.0.0.1 $port 2>&1 | grep 'open')" ]; then
        green "成功：端口号 $port 可用!"
        sign=true
    else
        red "错误：$port 已被占用！"
        read -p "请重新输入reality端口号：" port
    fi
done

UUID=$(cat /proc/sys/kernel/random/uuid)
read -p "请输入回落域名[默认: www.microsoft.com]: " dest_server
[ -z "$dest_server" ] && dest_server="www.microsoft.com"
short_id=$(dd bs=4 count=2 if=/dev/urandom 2>/dev/null | xxd -p -c 8)

# 使用 sing-box 生成 Reality 密钥对
keys=$(/root/singbox/sing-box generate reality-keypair)
private_key=$(echo "$keys" | grep PrivateKey | awk '{print $2}')
public_key=$(echo "$keys" | grep PublicKey | awk '{print $2}')

green "private_key: $private_key"
green "public_key: $public_key"
green "short_id: $short_id"

rm -f /root/singbox/config.json
# 生成极限精简版 Sing-box 配置文件（关闭日志，降低内存占用）
cat << EOF > /root/singbox/config.json
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
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$dest_server",
        "reality": {
          "enabled": true,
          "handshake": {
            "server_options": {
              "server_name": "$dest_server"
            }
          },
          "private_key": "$private_key",
          "short_id": [
            "$short_id"
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
EOF

IP=$(wget -qO- --no-check-certificate -U Mozilla https://api.ip.sb/geoip | sed -n 's/.*"ip": *"\([^"]*\).*/\1/p')
green "您的IP为：$IP"

share_link="vless://$UUID@$IP:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$dest_server&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#32M-SingBox"
echo ${share_link} > /root/singbox/share-link.txt

yellow "reality的分享链接已保存到：/root/singbox/share-link.txt"
echo
green "reality的分享链接为："
red $share_link

rm -f /etc/init.d/sing-box
cat << 'EOF' > /etc/init.d/sing-box
#!/sbin/openrc-run
name="sing-box"
description="Sing-box Service"

command="/root/singbox/sing-box"
command_args="run -c /root/singbox/config.json"
pidfile="/run/sing-box.pid"
command_background="yes"
rc_ulimit="-n 30000"

# 针对 32M 内存小鸡强制执行积极的内存垃圾回收
export GOGC=20
export GOMEMLIMIT=25MiB

depend() {
    need net
    after net
}

stop() {
   ebegin "Stopping sing-box"
   start-stop-daemon --stop --name sing-box
   eend $?
}
EOF

chmod u+x /etc/init.d/sing-box
if ! rc-update show | grep sing-box | grep 'default' > /dev/null; then
    rc-update add sing-box default
fi

# 重启并查看状态
service sing-box restart
service sing-box status

cd /root
EOF
