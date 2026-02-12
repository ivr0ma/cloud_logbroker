#!/bin/bash
set -e

LOGBROKER_1="${LOGBROKER_1:-10.2.0.20}"
LOGBROKER_2="${LOGBROKER_2:-10.2.0.22}"

echo "==> Установка nginx..."
sudo apt-get update
sudo apt-get install -y nginx

echo "==> Отключение default-сайта..."
sudo rm -f /etc/nginx/sites-enabled/default || true

echo "==> Конфигурация /etc/nginx/conf.d/logbroker.conf..."
sudo tee /etc/nginx/conf.d/logbroker.conf > /dev/null << EOF
upstream logbroker_backends {
    server ${LOGBROKER_1}:80;
    server ${LOGBROKER_2}:80;
}

server {
    listen 80;
    server_name _;

    location /nginx_health {
        return 200 "ok";
        add_header Content-Type text/plain;
    }

    location / {
        proxy_pass http://logbroker_backends;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }
}
EOF

echo "==> Проверка и перезапуск nginx..."
sudo nginx -t
sudo systemctl restart nginx
sudo systemctl enable nginx

echo "==> nginx настроен как балансировщик для logbroker."
