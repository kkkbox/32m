#!/bin/sh

red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }

# 1. 检查并下载 sing-box
if [ ! -f "/root/singbox/sing-box" ]; then
    echo "正在获取sing-box最新版本号..."
    last_version=$(wget -qO- https://api.github.com/repos/SagerNet/sing-box/releases | grep -m1 '"tag_name":' | cut -d '"' -f 4)
    [ -z "$last_version" ] && { red "获取版本号失败！"; exit 1; }
    
    file_version=$(echo $last_version | sed 's/^v//')
    wget "https://github.com/SagerNet/sing-box/releases/download/${last_version}/sing-box-${file_version}-linux-386.tar.gz" -O sing-box.tar.gz
    mkdir -p /root/singbox
    tar -xzf sing-box.tar.gz
    mv sing-box-${file_version}-linux-386/sing-box /root/singbox/
    rm -rf sing-box.tar.gz sing-box-${file_version}-linux-386
fi
green "sing-box文件已就绪！"

# 2. 交互输入配置
read -p "请输入reality端口号：" port
sign=false
until $sign; do
    if [ -z "$port" ] || ! echo "$port" | grep -qE '^[0-9]+$' || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        red "错误：请输入1~65535之间的有效数字!"
        read -p "请重新输入reality端口号：" port
        continue
    fi
    if nc -zv 127.0.0.1 $port 2>&1 | grep -q "open"; then
        red "错误：$port 已被占用！"
        read -p "请重新输入reality端口号：" port
    else
        green "成功：端口号 $port 可用!"
        sign=true
    fi
done

UUID=$(cat /proc/sys/kernel/random/uuid)
read -p "请输入回落域名[默认: www.microsoft.com]: " dest_server
[ -z "$dest_server" ] && dest_server="www.microsoft.com"
short_id=$(dd bs=4 count=2 if=/dev/urandom 2>/dev/null | xxd -p -c 8)

keys=$(/root/singbox/sing-box generate reality-keypair)
private_key=$(echo "$keys" | grep PrivateKey | awk '{print $2}')
public_key=$(echo "$keys" | grep PublicKey | awk '{print $2}')

green "private_key: $private_key"
green "public_key: $public_key"
green "short_id: $short_id"

# 3. 生成配置文件
cat << JSON_EOF > /root/singbox/config.json
{
  "log": { "disabled": true, "level": "fatal" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": $port,
      "users": [ { "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "$dest_server",
        "reality": {
          "enabled": true,
          "handshake": { "server_options": { "server_name": "$dest_server" } },
          "private_key": "$private_key",
          "short_id": [ "$short_id" ]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ]
}
JSON_EOF

# 4. 生成分享链接
IP=$(wget -qO- http://ipv4.icanhazip.com || wget -qO- http://ifconfig.me)
green "您的IP为：$IP"

share_link="vless://${UUID}@${IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${dest_server}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#32M-SingBox"
echo "$share_link" > /root/singbox/share-link.txt

yellow "reality的分享链接已保存到：/root/singbox/share-link.txt"
echo
green "reality的分享链接为："
red "$share_link"

# 5. 配置守护进程并针对32M内存进行特调
cat << 'SVC_EOF' > /etc/init.d/sing-box
#!/sbin/openrc-run
name="sing-box"
command="/root/singbox/sing-box"
command_args="run -c /root/singbox/config.json"
pidfile="/run/sing-box.pid"
command_background="yes"
rc_ulimit="-n 30000"
export GOGC=20
export GOMEMLIMIT=25MiB
depend() { need net; after net; }
SVC_EOF

chmod u+x /etc/init.d/sing-box
rc-update -q add sing-box default
service sing-box restart
service sing-box status
