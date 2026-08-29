#!/bin/bash
# IP 池体检脚本：查询 pixiv 四个域名的真实 A 记录 + 探测现有池 IP 存活状态
# 用法（Windows Git Bash / WSL / macOS / Linux 均可）：
#   bash tools/ip_pool_check.sh
# 输出：
#   1) 各域名 DoH 解析结果（多源，取交集更可靠）
#   2) 现有池 IP 的 443 连通性（ALIVE/DEAD）
# 把输出贴回给分析工具，据此更新 lib/er/hoster.dart 的硬编码池

set -u

DOH_SERVERS=(
  "https://1.1.1.1/dns-query"          # Cloudflare（JSON）
  "https://77.88.8.1/dns-query"        # Yandex（JSON）
  "https://dns.google/resolve"         # Google（JSON）
  "https://dns.alidns.com/resolve"     # 阿里（JSON）
)
DOMAINS=(
  "i.pximg.net"
  "s.pximg.net"
  "app-api.pixiv.net"
  "oauth.secure.pixiv.net"
)

echo "================ DoH 解析结果 ================"
for host in "${DOMAINS[@]}"; do
  echo "=== $host ==="
  declare -A seen
  for srv in "${DOH_SERVERS[@]}"; do
    json=$(curl -s --max-time 8 -H "accept: application/dns-json" "$srv?name=$host&type=A" 2>/dev/null)
    if [ -n "$json" ]; then
      # 提取 Answer 中的 IPv4（jq 存在时用 jq，否则 grep 兜底）
      ips=$(echo "$json" | jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null || \
            echo "$json" | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | cut -d'"' -f4)
      for ip in $ips; do
        if [ -z "${seen[$ip]:-}" ]; then
          echo "  $ip  ($srv)"
          seen[$ip]=1
        fi
      done
    fi
  done
done

echo ""
echo "================ 现有池 IP 443 连通性 ================"
# API 池
echo "--- API 池 ---"
for ip in 210.140.139.154 210.140.139.156 210.140.139.157 210.140.139.158 210.140.139.159 210.140.139.160 210.140.139.161; do
  out=$(curl -s --connect-timeout 2 --max-time 4 -o /dev/null -w "%{http_code}|%{errormsg}" "https://$ip/" 2>/dev/null)
  code=${out%%|*}
  err=${out##*|}
  case "$err" in
    *"timed out"*) echo "  $ip DEAD (connect timeout)" ;;
    *"refused"*)   echo "  $ip DEAD (refused)" ;;
    *)             echo "  $ip ALIVE (http=$code)" ;;
  esac
done
echo "--- 图片池 ---"
for ip in 210.140.139.131 210.140.139.132 210.140.139.133 210.140.139.134 210.140.139.135 210.140.139.136 210.140.139.137 210.140.139.138 210.140.139.149 210.140.139.150; do
  out=$(curl -s --connect-timeout 2 --max-time 4 -o /dev/null -w "%{http_code}|%{errormsg}" "https://$ip/" 2>/dev/null)
  code=${out%%|*}
  err=${out##*|}
  case "$err" in
    *"timed out"*) echo "  $ip DEAD (connect timeout)" ;;
    *"refused"*)   echo "  $ip DEAD (refused)" ;;
    *)             echo "  $ip ALIVE (http=$code)" ;;
  esac
done

echo ""
echo "说明："
echo "  - ALIVE 判定为 TCP 443 可达（TLS 证书错误/HTTP 4xx 均视为 TCP 通）"
echo "  - 替换池时优先使用 DoH 多源交集 + 实测 ALIVE 的 IP"
echo "  - 注意 API 域（app-api/oauth）与图片域（i.pximg/s.pximg）的池需分开验证"
