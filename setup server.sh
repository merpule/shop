#!/usr/bin/env bash
# Полная установка бота и HTTPS на сервер одной командой. Запуск от root: bash setup_server.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Запусти от root"; exit 1; }
export DEBIAN_FRONTEND=noninteractive
APP=/opt/chrome_street

echo "== Шаг 1/6: программы"
apt-get update -y
apt-get install -y curl unzip git ca-certificates

IP=$(curl -s https://api.ipify.org || true)
[ -n "$IP" ] || IP=$(hostname -I | awk '{print $1}')
DOMAIN="$(echo "$IP" | tr . -).sslip.io"

read -r -p "Вставь токен бота от BotFather и нажми Enter: " TOKEN </dev/tty
[ -n "$TOKEN" ] || { echo "Токен пустой, запусти заново"; exit 1; }

echo "== Шаг 2/6: проект с GitHub"
rm -rf /root/shop
git clone https://github.com/merpule/shop.git /root/shop
cd /root/shop
unzip -o chrome_street_repo.zip
SRC=/root/shop/chrome_street

echo "== Шаг 3/6: Python 3.12 и библиотеки"
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
systemctl stop chrome-street 2>/dev/null || true
id chromebot >/dev/null 2>&1 || useradd -r -m -d "$APP" -s /usr/sbin/nologin chromebot
mkdir -p "$APP"
rm -rf "$APP/venv"
export UV_PYTHON_INSTALL_DIR="$APP/python"   # Python лежит в /opt, чтобы служба могла его запустить
uv venv -p 3.12 "$APP/venv"
uv pip install -p "$APP/venv/bin/python" -U aiogram aiohttp

echo "== Шаг 4/6: файлы бота"
cp "$SRC/bot.py" "$SRC/index.html" "$APP/"
printf 'BOT_TOKEN = "%s"\nWEBAPP_URL = "https://%s"\n' "$TOKEN" "$DOMAIN" > "$APP/local_settings.py"
chmod 600 "$APP/local_settings.py"
chown -R chromebot:chromebot "$APP"
cat > /etc/systemd/system/chrome-street.service <<UNIT
[Unit]
Description=Chrome Street Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
User=chromebot
WorkingDirectory=$APP
ExecStart=$APP/venv/bin/python bot.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT

echo "== Шаг 5/6: HTTPS (Caddy) для адреса $DOMAIN"
case "$(uname -m)" in aarch64) A=arm64 ;; *) A=amd64 ;; esac
curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$A" -o /usr/local/bin/caddy
chmod +x /usr/local/bin/caddy
mkdir -p /etc/caddy
printf '%s {\n    reverse_proxy 127.0.0.1:8080\n}\n' "$DOMAIN" > /etc/caddy/Caddyfile
cat > /etc/systemd/system/caddy.service <<UNIT
[Unit]
Description=Caddy
After=network.target

[Service]
Environment=HOME=/root
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp
fi

echo "== Шаг 6/6: запуск"
systemctl daemon-reload
systemctl enable chrome-street caddy
systemctl restart chrome-street caddy
sleep 5
systemctl --no-pager --lines=12 status chrome-street || true
echo
echo "Готово. Напиши боту /start. Мини-приложение: https://$DOMAIN"
echo "Логи бота: journalctl -u chrome-street -n 30"
