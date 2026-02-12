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

### 2. Что делает `terraform apply`

Один `terraform apply` поднимает и настраивает всю инфраструктуру и софт:

- **VPC и сеть**: отдельная сеть, публичная и приватная подсети, таблица маршрутизации.
- **NAT‑инстанс**:
  - Включается IP‑forwarding.
  - Вешается iptables‑правило `MASQUERADE` для подсети `10.2.0.0/24`.
  - Приватные ВМ получают доступ в интернет.
- **ClickHouse‑ВМ**:
  - Устанавливается Docker.
  - Поднимается контейнер `clickhouse/clickhouse-server`.
  - Создаётся база/таблица `default.logs`.
  - Создаётся пользователь `logbroker` с паролем `logbroker` и правами `INSERT, SELECT` на `default.logs`.
- **Две backend‑ВМ с logbroker**:
  - Копируется каталог `logbroker/` и скрипт `scripts/setup_logbroker.sh`.
  - Устанавливается Python, создаётся `venv`, ставятся зависимости.
  - Создаётся каталог `/var/lib/logbroker` под персистентный буфер.
  - Разворачивается и запускается `systemd`‑сервис `logbroker` на порту 80.
  - В сервис пробрасываются переменные окружения `CLICKHOUSE_HOST`, `CLICKHOUSE_USER=logbroker`, `CLICKHOUSE_PASSWORD=logbroker`.
- **nginx‑ВМ**:
  - Устанавливается nginx.
  - Удаляется дефолтный сайт.
  - Создаётся конфиг `logbroker.conf` с `upstream` на два backend‑инстанса.
  - Включаются маршруты `/nginx_health` и проксирование всех остальных запросов на logbroker.

Никаких ручных запусков `setup_*.sh` делать не нужно: Terraform сам копирует и выполняет скрипты по SSH.

---

### 3. Проверка инфраструктуры

После `terraform apply` можно посмотреть ключевые параметры:

```bash
terraform output
```

Важно:

- `nginx_public_ip` — публичный IP nginx‑балансировщика.
- `nat_instance_public_ip` — публичный IP NAT/jump‑host.
- `clickhouse_private_ip` — приватный IP ClickHouse.
- `logbroker_private_ips` — приватные IP двух backend‑ВМ.

Быстрая проверка nginx:

```bash
curl http://$(terraform output -raw nginx_public_ip)/nginx_health
curl http://$(terraform output -raw nginx_public_ip)/health
```

Проверка ClickHouse:

```bash
ssh -J ubuntu@$(terraform output -raw nat_instance_public_ip) ubuntu@$(terraform output -raw clickhouse_private_ip)

curl http://localhost:8123/ping
sudo docker exec -it clickhouse-server clickhouse-client -q "SHOW TABLES FROM default"
```

Ожидается таблица `logs`.

---

### 4. End‑to‑end проверка логов

С локальной машины отправить логи через nginx:

```bash
curl -X POST "http://$(terraform output -raw nginx_public_ip)/write_log" \
  -d $'first log via nginx\nsecond log via nginx'
```

Через несколько секунд проверить в ClickHouse:

```bash
ssh -J ubuntu@$(terraform output -raw nat_instance_public_ip) ubuntu@$(terraform output -raw clickhouse_private_ip)
sudo docker exec -it clickhouse-server clickhouse-client -q "SELECT count(), any(message) FROM default.logs"
```

Ожидаемый результат: `count()` > 0, в сообщении видна одна из отправленных строк.

---

### 5. Кратко про гарантию доставки

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
