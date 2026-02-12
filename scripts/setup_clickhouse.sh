#!/bin/bash
# Запуск на ВМ ClickHouse (10.2.0.24).
# Подключение: ssh -J ubuntu@<NAT_PUBLIC_IP> ubuntu@10.2.0.24

set -e

CH_USER="${SUDO_USER:-$USER}"
DATA_DIR="/home/${CH_USER}/logbroker_clickhouse_database"
IMAGE="${CLICKHOUSE_IMAGE:-clickhouse/clickhouse-server}"

echo "==> Установка Docker (если ещё не установлен)..."
if ! command -v docker &>/dev/null; then
  sudo apt-get update
  sudo apt-get install -y docker.io
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$CH_USER"
  echo "Docker установлен. Возможно, потребуется выйти и зайти по SSH для группы docker."
fi

# На случай если docker установлен, но сервис не запущен
sudo systemctl start docker 2>/dev/null || true

echo "==> Создание директории данных..."
mkdir -p "$DATA_DIR"
chown "$CH_USER:$CH_USER" "$DATA_DIR" 2>/dev/null || true

echo "==> Остановка старого контейнера (если есть)..."
sudo docker stop clickhouse-server 2>/dev/null || true
sudo docker rm clickhouse-server 2>/dev/null || true

echo "==> Запуск ClickHouse..."
sudo docker run -d \
  --name clickhouse-server \
  --ulimit nofile=262144:262144 \
  --volume="$DATA_DIR:/var/lib/clickhouse" \
  -p 8123:8123 \
  -p 9000:9000 \
  "$IMAGE"

echo "==> Ожидание старта ClickHouse (10 сек)..."
sleep 10

echo "==> Создание таблицы default.logs..."
sudo docker exec clickhouse-server clickhouse-client -q "
CREATE TABLE IF NOT EXISTS default.logs
(
    ts      DateTime,
    message String
)
ENGINE = MergeTree()
ORDER BY ts;
"

echo "==> Создание пользователя logbroker и прав..."
sudo docker exec clickhouse-server clickhouse-client -q "
CREATE USER IF NOT EXISTS logbroker IDENTIFIED BY 'logbroker';
GRANT INSERT, SELECT ON default.logs TO logbroker;
"

echo "==> Готово. ClickHouse слушает порты 8123 (HTTP) и 9000 (native)."
echo "Проверка: curl http://localhost:8123/ping"
