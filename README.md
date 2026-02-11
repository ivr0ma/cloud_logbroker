### Cloud Logbroker — инструкция по запуску

Это репозиторий для задания по развёртыванию простого logbroker‑сервиса в Yandex Cloud:

- инфраструктура в YC через Terraform (VPC, NAT, 2 backend‑ВМ с logbroker, ClickHouse, nginx),
- ClickHouse для хранения логов,
- приложение logbroker с персистентной буферизацией,
- nginx как балансировщик.

---

### 0. Предварительные требования

- Установлены: `yc`, `terraform` (или OpenTofu с совместимым CLI), `ssh`, `scp`.
- В YC создан сервисный аккаунт с правами на создание ВМ и сеть.
- Получен `cloud_id`, `folder_id`, зона (например `ru-central1-b`).
- Сгенерирован SSH‑ключ (`ssh-ed25519` или `rsa`).

Экспорт токена для YC:

```bash
export YC_TOKEN=$(yc iam create-token --impersonate-service-account-id <service_account_ID>)
```

---

### 1. Настройка Terraform

1. Заполнить `terraform.tfvars`:

```hcl
cloud_id       = "b1g..."
folder_id      = "b1g..."
zone           = "ru-central1-b"
ssh_public_key = "ssh-ed25519 AAAA... your-key-comment"
```

2. Инициализировать Terraform:

```bash
terraform init
```

3. Посмотреть план и применить:

```bash
terraform plan
terraform apply
```

4. После успешного `apply` посмотреть выходные значения:

```bash
terraform output
```

Будут выведены:

- `nginx_public_ip` — публичный IP nginx,
- `nat_instance_public_ip` — публичный IP NAT/jump‑host,
- `logbroker_private_ips` — приватные IP двух backend‑ВМ,
- `clickhouse_private_ip` — приватный IP ClickHouse.

Далее в README предполагается, что:

- NAT: `89.169.181.22`,
- nginx: `89.169.188.57`,
- logbroker: `10.2.0.20`, `10.2.0.22`,
- ClickHouse: `10.2.0.24`.

Заменяйте на свои значения.

---

### 2. NAT‑инстанс (jump‑host и выход в интернет)

Подключение к NAT:

```bash
ssh ubuntu@89.169.181.22
```

На NAT‑инстансе включить IP‑forwarding и NAT:

```bash
sudo sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.d/99-nat.conf

sudo iptables -t nat -A POSTROUTING -s 10.2.0.0/24 -o eth0 -j MASQUERADE
```

Теперь приватные ВМ могут выходить в интернет через NAT.

Удобная конфигурация SSH (`~/.ssh/config` на локальной машине):

```sshconfig
Host hw2-nat
  HostName 89.169.181.22
  User ubuntu

Host hw2-clickhouse
  HostName 10.2.0.24
  User ubuntu
  ProxyJump hw2-nat

Host hw2-logbroker-1
  HostName 10.2.0.20
  User ubuntu
  ProxyJump hw2-nat

Host hw2-logbroker-2
  HostName 10.2.0.22
  User ubuntu
  ProxyJump hw2-nat
```

После этого можно подключаться как:

```bash
ssh hw2-clickhouse
ssh hw2-logbroker-1
ssh hw2-logbroker-2
```

---

### 3. Установка ClickHouse

Скопировать скрипт установки:

```bash
scp scripts/setup_clickhouse.sh hw2-clickhouse:~/
```

Запустить:

```bash
ssh hw2-clickhouse 'chmod +x setup_clickhouse.sh && ./setup_clickhouse.sh'
```

Скрипт:

- устанавливает Docker,
- создаёт директорию `/home/ubuntu/logbroker_clickhouse_database`,
- поднимает контейнер ClickHouse (`clickhouse/clickhouse-server`),
- создаёт таблицу:

```sql
CREATE TABLE IF NOT EXISTS default.logs
(
    ts      DateTime,
    message String
)
ENGINE = MergeTree()
ORDER BY ts;
```

Проверка:

На ВМ ClickHouse (`10.2.0.24`):

```bash
ssh hw2-clickhouse
```

```bash
curl http://localhost:8123/ping
# Должно вернуть: Ok.

sudo docker exec -it clickhouse-server clickhouse-client -q "SHOW TABLES FROM default"
# Должно быть: logs
```

---

### 4. Пользователь для logbroker в ClickHouse

На `10.2.0.24`:

```bash
ssh hw2-clickhouse
sudo docker exec -it clickhouse-server clickhouse-client
```

Внутри клиента:

```sql
CREATE USER logbroker IDENTIFIED BY 'logbroker';
GRANT INSERT, SELECT ON default.logs TO logbroker;
```

---

### 5. Развёртывание logbroker на двух backend‑ВМ

Приложение находится в каталоге `logbroker/`:

- FastAPI‑приложение (`main.py`),
- персистентный буфер (`buffer.py`), пишущий в файл и раз в секунду отправляющий батчи в ClickHouse,
- конфиг через переменные окружения (`config.py`).

#### 5.1. Копирование кода и скрипта

С локальной машины:

```bash
scp -r logbroker hw2-logbroker-1:~/
scp -r logbroker hw2-logbroker-2:~/

scp scripts/setup_logbroker.sh hw2-logbroker-1:~/
scp scripts/setup_logbroker.sh hw2-logbroker-2:~/
```

#### 5.2. Установка и запуск на 10.2.0.20

```bash
ssh hw2-logbroker-1
chmod +x setup_logbroker.sh

LOGBROKER_DIR=/home/ubuntu/logbroker \
CLICKHOUSE_USER=logbroker \
CLICKHOUSE_PASSWORD=logbroker \
./setup_logbroker.sh

sudo systemctl restart logbroker
sudo journalctl -u logbroker -n 10 --no-pager
```

Скрипт:

- устанавливает `python3`, `pip`, `venv`,
- создаёт виртуальное окружение и ставит зависимости из `logbroker/requirements.txt`,
- создаёт каталог `/var/lib/logbroker` под буфер,
- разворачивает и запускает `systemd`‑сервис `logbroker` на порту 80.

Проверка:

```bash
curl -s http://localhost/health
```

Аналогично на `10.2.0.22`:

```bash
ssh hw2-logbroker-2
chmod +x setup_logbroker.sh

LOGBROKER_DIR=/home/ubuntu/logbroker \
CLICKHOUSE_HOST=10.2.0.20 \
CLICKHOUSE_USER=logbroker \
CLICKHOUSE_PASSWORD=logbroker \
./setup_logbroker.sh

sudo systemctl restart logbroker
sudo journalctl -u logbroker -n 10 --no-pager
curl -s http://localhost/health
```

---

### 6. Настройка nginx‑балансировщика

На ВМ nginx (`nginx_public_ip`, в примере `89.169.188.57`):

```bash
ssh ubuntu@89.169.188.57
sudo apt-get update
sudo apt-get install -y nginx

sudo rm -f /etc/nginx/sites-enabled/default
```

Создать конфиг `/etc/nginx/conf.d/logbroker.conf`:

```bash
sudo tee /etc/nginx/conf.d/logbroker.conf > /dev/null << 'EOF'
upstream logbroker_backends {
    server 10.2.0.23:80;
    server 10.2.0.25:80;
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

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }
}
EOF

sudo nginx -t
sudo systemctl restart nginx
sudo systemctl enable nginx
```

Проверки:

```bash
curl http://89.169.188.57/nginx_health
curl http://89.169.188.57/health
```

---

### 7. End‑to‑end проверка логов

С локальной машины отправить логи:

```bash
curl -X POST http://89.169.188.57/write_log -d $'first log via nginx\nsecond log via nginx'
```

Через несколько секунд проверить в ClickHouse:

```bash
ssh hw2-clickhouse
sudo docker exec -it clickhouse-server clickhouse-client -q "SELECT count(), any(message) FROM default.logs"
```

Ожидаемый результат: `count()` > 0, в сообщении видна одна из отправленных строк.

---

### 8. Кратко про гарантию доставки

Logbroker:

- принимает запрос `/write_log`,
- **сначала** пишет строки логов в файл (`/var/lib/logbroker/buffer.log`) и fsync,
- только потом отвечает `200 OK`,
- отдельная задача раз в секунду читает буфер и одной вставкой отправляет данные в ClickHouse через HTTP API,
- при успешной вставке очищает файл буфера,
- при остановке сервиса выполняет финальный `flush`.

Благодаря этому:

- сервис переживает перезапуск (буфер на диске),
- выполняет вставки в ClickHouse не чаще раза в секунду,
- все принятые (подтверждённые 200 OK) логи гарантированно будут доставлены в ClickHouse (с возможными повторами при сетевых ошибках).
