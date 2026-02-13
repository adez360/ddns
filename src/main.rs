use std::{fs, time::Duration, sync::Arc, net::IpAddr, process};
use reqwest::Client;
use serde::Deserialize;
use serde_json::json;

#[derive(Deserialize)]
struct Config {
    cf_token: String,
    zone_id: String,
    record_a_id: String,
    record_aaaa_id: String,
    domain: String,
    interface_name: Option<String>,
}

const CONFIG_PATH: &str = "/etc/ddns/config.json";
const CACHE_FILE: &str = "/dev/shm/rust_ddns_cache";

const V4_PROVIDERS: &[&str] = &["https://api.ipify.org", "https://v4.ident.me", "https://checkip.amazonaws.com"];
const V6_PROVIDERS: &[&str] = &["https://api64.ipify.org", "https://v6.ident.me", "https://icanhazip.com"];

async fn get_public_ip(client: &Client, providers: &[&str], is_v6: bool) -> Option<String> {
    for url in providers {
        let Ok(resp) = client.get(*url).timeout(Duration::from_secs(3)).send().await else { continue };
        let Ok(text) = resp.text().await else { continue };
        let ip = text.trim().to_string();
        if (is_v6 && ip.contains(':')) || (!is_v6 && ip.contains('.')) { return Some(ip); }
    }
    None
}

fn get_local_ipv6(interface_name: Option<&str>) -> Option<String> {
    let ifaces = if_addrs::get_if_addrs().ok()?;
    ifaces.into_iter().find_map(|iface| {
        if let Some(name) = interface_name { if iface.name != name { return None; } }
        if iface.is_loopback() { return None; }
        
        if let IpAddr::V6(addr) = iface.addr.ip() {
            if (addr.segments()[0] & 0xe000) == 0x2000 { return Some(addr.to_string()); }
        }
        None
    })
}

async fn update_record(client: &Client, config: &Config, rec_id: &str, rec_type: &str, ip: &str) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if rec_id.is_empty() || rec_id == "null" { return Ok(()); }

    let url = format!("https://api.cloudflare.com/client/v4/zones/{}/dns_records/{}", config.zone_id, rec_id);
    let body = json!({ "type": rec_type, "name": config.domain, "content": ip, "ttl": 60, "proxied": false });

    let resp = client.put(url).bearer_auth(&config.cf_token).json(&body).send().await?;
    if !resp.status().is_success() {
        eprintln!("[{}] 更新失敗: {}", rec_type, resp.text().await?);
    } else {
        println!("[{}] 更新成功: {}", rec_type, ip);
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let Ok(content) = fs::read_to_string(CONFIG_PATH) else {
        eprintln!("找不到設定檔 {}", CONFIG_PATH);
        process::exit(1);
    };
    
    let config = Arc::new(serde_json::from_str::<Config>(&content)?);
    let client = Client::builder().timeout(Duration::from_secs(10)).build()?;

    let v4_future = get_public_ip(&client, V4_PROVIDERS, false);
    let v6_res = get_local_ipv6(config.interface_name.as_deref())
        .or(get_public_ip(&client, V6_PROVIDERS, true).await);

    let current_v4 = v4_future.await.unwrap_or_default();
    let current_v6 = v6_res.unwrap_or_default();
    
    let combined = format!("{current_v4}|{current_v6}");
    
    // 修正編譯錯誤：使用 if let 處理快取比對
    if let Ok(last_ip) = fs::read_to_string(CACHE_FILE) {
        if last_ip.trim() == combined {
            println!("IP 未變動，跳過更新。");
            return Ok(());
        }
    }

    let mut tasks = vec![];
    
    // 修正編譯錯誤：這裡將 rec_id 從 &String 改為 clone() 出來的 String，確保任務擁有資料
    for (ip, rec_id, rec_type) in [(current_v4, config.record_a_id.clone(), "A"), (current_v6, config.record_aaaa_id.clone(), "AAAA")] {
        if !ip.is_empty() {
            let (c, cfg, ip_val, id_val) = (client.clone(), Arc::clone(&config), ip.clone(), rec_id);
            tasks.push(tokio::spawn(async move {
                let _ = update_record(&c, &cfg, &id_val, rec_type, &ip_val).await;
            }));
        }
    }

    for t in tasks { t.await?; }
    fs::write(CACHE_FILE, combined)?;
    Ok(())
}
