#!/bin/bash
# Запуск на ВМ logbroker (10.2.0.20 или 10.2.0.22).
# Подключение: ssh -J ubuntu@<NAT_PUBLIC_IP> ubuntu@10.2.0.20 (или .22)
#
# Перед запуском скопируйте папку logbroker в домашнюю директорию на ВМ:
#   scp -o ProxyJump=ubuntu@<NAT_IP> -r logbroker ubuntu@10.2.0.20:~/

set -e

CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-10.2.0.24}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-logbroker}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-logbroker}"
LOGBROKER_DIR="${1:-$HOME/logbroker}"

if [ ! -d "$LOGBROKER_DIR" ]; then
  echo "Папка $LOGBROKER_DIR не найдена. Скопируйте logbroker на ВМ и укажите путь."
  exit 1
fi

echo "==> Установка Python3 и venv..."
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv

echo "==> Создание виртуального окружения и установка зависимостей..."
cd "$LOGBROKER_DIR"
python3 -m venv venv
./venv/bin/pip install -r requirements.txt

echo "==> Директория для буфера..."
sudo mkdir -p /var/lib/logbroker
sudo chown "$USER:$USER" /var/lib/logbroker

echo "==> Установка systemd unit и запуск сервиса..."
sudo tee /etc/systemd/system/logbroker.service > /dev/null << EOF
[Unit]
Description=Logbroker service
After=network.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=$LOGBROKER_DIR
Environment="CLICKHOUSE_HOST=$CLICKHOUSE_HOST"
Environment="CLICKHOUSE_PORT=8123"
Environment="CLICKHOUSE_USER=$CLICKHOUSE_USER"
Environment="CLICKHOUSE_PASSWORD=$CLICKHOUSE_PASSWORD"
Environment="BUFFER_PATH=/var/lib/logbroker/buffer.log"
ExecStart=$LOGBROKER_DIR/venv/bin/uvicorn main:app --host 0.0.0.0 --port 80
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Разрешить привязку к порту 80 без root
PYTHON_BIN="$LOGBROKER_DIR/venv/bin/python3"
if [ -f "$PYTHON_BIN" ]; then
  sudo setcap 'cap_net_bind_service=+ep' "$(readlink -f "$PYTHON_BIN")" 2>/dev/null || true
fi

sudo systemctl daemon-reload
sudo systemctl enable logbroker
sudo systemctl start logbroker

echo "==> Готово. Logbroker запущен как сервис (порт 80)."
echo "Проверка: curl http://localhost/health"
echo "Логи: sudo journalctl -u logbroker -f"
