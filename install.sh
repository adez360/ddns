#!/bin/bash

# --- 顏色設定 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}    Cloudflare DDNS 互動式配置助手        ${NC}"
echo -e "${GREEN}==========================================${NC}"

# 1. 互動式輸入
read -p "請貼上您的 Cloudflare API Token: " CF_TOKEN
read -p "請輸入您的主要網域 (例如 adex360.com): " ROOT_DOMAIN
read -p "請輸入您要使用的子網域 (例如 pc, 留空則使用主網域): " SUBDOMAIN

# 處理完整網域名稱
if [ -z "$SUBDOMAIN" ]; then
  FULL_DOMAIN="$ROOT_DOMAIN"
else
  FULL_DOMAIN="$SUBDOMAIN.$ROOT_DOMAIN"
fi

echo -e "\n${YELLOW}正在連線至 Cloudflare 驗證資訊...${NC}"

# 2. 獲取 Zone ID
ZONE_JSON=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ROOT_DOMAIN" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json")

ZONE_ID=$(echo $ZONE_JSON | grep -oP '"id":"\K[^"]+' | head -1)

if [ -z "$ZONE_ID" ]; then
  echo -e "${RED}錯誤：無法獲取 Zone ID。請檢查 Token 是否具備該網域的存取權限。${NC}"
  exit 1
fi
echo -e "成功獲取 Zone ID: ${GREEN}$ZONE_ID${NC}"

# 3. 定義檢查與創建函式
get_or_create_record() {
  local TYPE=$1
  local NAME=$2
  local CONTENT=$3 # 初始佔位 IP

  # 檢查紀錄是否存在
  local SEARCH=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$TYPE&name=$NAME" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json")

  local ID=$(echo $SEARCH | grep -oP '"id":"\K[^"]+' | head -1)

  if [ -z "$ID" ]; then
    echo -e "${YELLOW}找不到 $TYPE 紀錄 ($NAME)，正在自動創建...${NC}"
    local CREATE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
      -H "Authorization: Bearer $CF_TOKEN" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"$TYPE\",\"name\":\"$NAME\",\"content\":\"$CONTENT\",\"ttl\":60,\"proxied\":false}")

    ID=$(echo $CREATE | grep -oP '"id":"\K[^"]+' | head -1)

    if [ -n "$ID" ]; then
      echo -e "成功創建 $TYPE 紀錄，ID: ${GREEN}$ID${NC}"
    else
      echo -e "${RED}創建 $TYPE 紀錄失敗！請檢查 Token 權限。${NC}"
    fi
  else
    echo -e "找到現有的 $TYPE 紀錄，ID: ${GREEN}$ID${NC}"
  fi
  echo "$ID"
}

# 執行 A 與 AAAA 的獲取或創建
RECORD_A_ID=$(get_or_create_record "A" "$FULL_DOMAIN" "1.2.3.4")
RECORD_AAAA_ID=$(get_or_create_record "AAAA" "$FULL_DOMAIN" "::1")

# 4. 寫入設定檔
sudo mkdir -p /etc/ddns
sudo bash -c "cat <<EOF > /etc/ddns/config.json
{
  \"cf_token\": \"$CF_TOKEN\",
  \"zone_id\": \"$ZONE_ID\",
  \"record_a_id\": \"$RECORD_A_ID\",
  \"record_aaaa_id\": \"$RECORD_AAAA_ID\",
  \"domain\": \"$FULL_DOMAIN\",
  \"interface_name\": null
}
EOF"

sudo chmod 600 /etc/ddns/config.json

echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}    配置完成！所有資訊已存入 config.json${NC}"
echo -e "${GREEN}    您的網域: $FULL_DOMAIN${NC}"
echo -e "${GREEN}==========================================${NC}"

# 詢問是否立即測試
read -p "是否立即執行一次更新測試? (y/n): " RUN_NOW
if [ "$RUN_NOW" == "y" ]; then
  sudo systemctl start ddns.service
  journalctl -u ddns.service -n 15
fi
