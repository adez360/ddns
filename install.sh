#!/bin/bash

# --- 顏色與排版 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}    Rust Cloudflare DDNS 終極部署工具     ${NC}"
echo -e "${GREEN}==========================================${NC}"

# 1. 環境檢查與 Rust 安裝
if ! command -v cargo &> /dev/null; then
    echo -e "${YELLOW}偵測到未安裝 Rust，正在啟動安裝程序...${NC}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi
rustup default stable &> /dev/null
source "$HOME/.cargo/env"

# 2. 編譯
echo -e "${GREEN}Step 1: 正在編譯 Release 版本...${NC}"
cargo build --release
if [ $? -ne 0 ]; then echo -e "${RED}編譯失敗！${NC}"; exit 1; fi

# 3. 部署系統檔案 (需要 sudo)
echo -e "${GREEN}Step 2: 正在部署系統服務與執行檔 (請輸入密碼)...${NC}"
sudo bash <<EOF
    mkdir -p /etc/ddns
    cp target/release/ddns /usr/local/bin/rust-ddns
    chmod +x /usr/local/bin/rust-ddns

    # 建立 Service
    cat <<SERVICE > /etc/systemd/system/ddns.service
[Unit]
Description=Cloudflare DDNS Update Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rust-ddns
User=root
SERVICE

    # 建立 Timer
    cat <<TIMER > /etc/systemd/system/ddns.timer
[Unit]
Description=Run DDNS update every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
TIMER

    systemctl daemon-reload
EOF

# 4. 互動式 Cloudflare 設定
echo -e "\n${GREEN}Step 3: 開始互動式配置${NC}"
read -p "請貼上您的 Cloudflare API Token: " CF_TOKEN
read -p "請輸入您的主要網域 (例如 adez360.com): " ROOT_DOMAIN
read -p "請輸入您要使用的子網域 (例如 pc, 留空則使用主網域): " SUBDOMAIN

FULL_DOMAIN="${SUBDOMAIN:+$SUBDOMAIN.}$ROOT_DOMAIN"

# 獲取 Zone ID
echo -e "${YELLOW}連線 Cloudflare 獲取 Zone ID...${NC}"
ZONE_JSON=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ROOT_DOMAIN" -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json")
ZONE_ID=$(echo $ZONE_JSON | grep -oP '"id":"\K[^"]+' | head -1)

if [ -z "$ZONE_ID" ]; then echo -e "${RED}錯誤：找不到 Zone ID。${NC}"; exit 1; fi

# 檢查/建立 紀錄的函式
get_or_create() {
    local TYPE=$1
    local NAME=$2
    local CONTENT=$3
    local SEARCH=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$TYPE&name=$NAME" -H "Authorization: Bearer $CF_TOKEN")
    local ID=$(echo $SEARCH | grep -oP '"id":"\K[^"]+' | head -1)
    
    if [ -z "$ID" ]; then
        echo -e "${YELLOW}正在建立新的 $TYPE 紀錄...${NC}"
        local CREATE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" --data "{\"type\":\"$TYPE\",\"name\":\"$NAME\",\"content\":\"$CONTENT\",\"ttl\":60,\"proxied\":false}")
        ID=$(echo $CREATE | grep -oP '"id":"\K[^"]+' | head -1)
    fi
    echo "$ID"
}

RECORD_A_ID=$(get_or_create "A" "$FULL_DOMAIN" "1.2.3.4")
RECORD_AAAA_ID=$(get_or_create "AAAA" "$FULL_DOMAIN" "::1")

# 5. 寫入設定檔並啟動
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
sudo systemctl enable --now ddns.timer

echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}    安裝與設定全部完成！${NC}"
echo -e "${GREEN}    網域: $FULL_DOMAIN${NC}"
echo -e "${YELLOW}    正在執行第一次 IP 更新測試...${NC}"
sudo systemctl start ddns.service
journalctl -u ddns.service -n 10
echo -e "${GREEN}==========================================${NC}"
