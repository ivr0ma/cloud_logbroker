terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

variable "cloud_id" {
  description = "Yandex Cloud ID"
  type        = string
}

variable "folder_id" {
  description = "Yandex Cloud folder ID"
  type        = string
}

variable "zone" {
  description = "Yandex Cloud zone"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for access to the VM (format: ssh-rsa AAAA...)"
  type        = string
  sensitive   = true
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key that matches ssh_public_key"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

# Provider for yandex cloud
provider "yandex" {
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = var.zone
}

########################
## СЕТЬ И МАРШРУТИЗАЦИЯ
########################

# Отдельная сеть для задания
resource "yandex_vpc_network" "hw2_network" {
  name = "hw2-network"
}

# Публичная подсеть (nginx + NAT-инстанс)
resource "yandex_vpc_subnet" "hw2_public_subnet" {
  name           = "hw2-public-subnet"
  zone           = var.zone
  network_id     = yandex_vpc_network.hw2_network.id
  v4_cidr_blocks = ["10.2.0.0/28"]
}

# Таблица маршрутизации для приватной подсети
resource "yandex_vpc_route_table" "hw2_route_table" {
  name       = "hw2-route-table"
  network_id = yandex_vpc_network.hw2_network.id

  # Маршрут по умолчанию через NAT-инстанс (его приватный IP в публичной подсети)
  static_route {
    destination_prefix = "0.0.0.0/0"
    next_hop_address   = yandex_compute_instance.nat_instance.network_interface[0].ip_address
  }
}

# Приватная подсеть (backend-ы и ClickHouse)
resource "yandex_vpc_subnet" "hw2_private_subnet" {
  name           = "hw2-private-subnet"
  zone           = var.zone
  network_id     = yandex_vpc_network.hw2_network.id
  v4_cidr_blocks = ["10.2.0.16/28"]

  # Ассоциируем таблицу маршрутизации напрямую с приватной подсетью
  route_table_id = yandex_vpc_route_table.hw2_route_table.id
}

########################
## NAT ИНСТАНС (jump + NAT)
########################

resource "yandex_compute_instance" "nat_instance" {
  name        = "hw2-nat-instance"
  platform_id = "standard-v3"
  zone        = var.zone

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      # Базовый образ Ubuntu, можно заменить на рекомендованный NAT-образ из маркетплейса
      image_id = "fd8vhban0amqsqutsjk7" # Ubuntu 24.04 LTS
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.hw2_public_subnet.id
    nat       = true # Публичный адрес для NAT и jump-хоста
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }
}

########################
## PROVISIONING: NAT (IP forwarding + MASQUERADE)
########################

resource "null_resource" "setup_nat" {
  triggers = {
    nat_ip = yandex_compute_instance.nat_instance.network_interface[0].nat_ip_address
  }

  provisioner "local-exec" {
    working_dir = path.module

    command = <<-EOT
      set -e
      NAT_IP="${yandex_compute_instance.nat_instance.network_interface[0].nat_ip_address}"
      SSH_KEY="${var.ssh_private_key_path}"

      echo "==> Настраиваю NAT-инстанс (IP forward + MASQUERADE)..."
      echo "==> Ожидаю, пока SSH на NAT-инстансе станет доступен..."

      # Ждём, пока SSH-порт поднимется (до 5 минут, 30 попыток по 10 секунд)
      for i in $(seq 1 30); do
        if ssh -i "$SSH_KEY" \
              -o StrictHostKeyChecking=no \
              -o ConnectTimeout=5 \
              ubuntu@"$NAT_IP" \
              "sudo sysctl -w net.ipv4.ip_forward=1 && echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-nat.conf >/dev/null && sudo iptables -t nat -C POSTROUTING -s 10.2.0.0/24 -o eth0 -j MASQUERADE 2>/dev/null || sudo iptables -t nat -A POSTROUTING -s 10.2.0.0/24 -o eth0 -j MASQUERADE"; then
          echo "==> NAT-инстанс успешно настроен."
          exit 0
        fi

        echo "==> SSH ещё недоступен, попытка $i/30, жду 10 секунд..."
        sleep 10
      done

      echo "==> Не удалось настроить NAT-инстанс: SSH так и не стал доступен."
      exit 1
    EOT
  }
}

########################
## NGINX (публичный балансировщик)
########################

resource "yandex_compute_instance" "nginx" {
  name        = "hw2-nginx"
  platform_id = "standard-v3"
  zone        = var.zone

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8vhban0amqsqutsjk7" # Ubuntu 24.04 LTS
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.hw2_public_subnet.id
    nat       = true # Единственный публичный сервис для пользователей (плюс NAT-инстанс)
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }
}

########################
## BACKEND LOGBROKER 1
########################

resource "yandex_compute_instance" "logbroker_1" {
  name        = "hw2-logbroker-1"
  platform_id = "standard-v3"
  zone        = var.zone

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8vhban0amqsqutsjk7" # Ubuntu 24.04 LTS
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.hw2_private_subnet.id
    nat       = false # Только приватный адрес, выход в интернет через NAT-инстанс
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }
}

########################
## BACKEND LOGBROKER 2
########################

resource "yandex_compute_instance" "logbroker_2" {
  name        = "hw2-logbroker-2"
  platform_id = "standard-v3"
  zone        = var.zone

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8vhban0amqsqutsjk7" # Ubuntu 24.04 LTS
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.hw2_private_subnet.id
    nat       = false
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }
}

########################
## CLICKHOUSE
########################

resource "yandex_compute_instance" "clickhouse" {
  name        = "hw2-clickhouse"
  platform_id = "standard-v3"
  zone        = var.zone

  resources {
    cores  = 4
    memory = 8
  }

  boot_disk {
    initialize_params {
      image_id = "fd8vhban0amqsqutsjk7" # Ubuntu 24.04 LTS
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.hw2_private_subnet.id
    nat       = false
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }
}

########################
## PROVISIONING: CLICKHOUSE
########################

resource "null_resource" "setup_clickhouse" {
  # Перезапускать провижининг, если меняется приватный IP (пересоздание ВМ)
  triggers = {
    clickhouse_ip = yandex_compute_instance.clickhouse.network_interface[0].ip_address
    nat_ip        = yandex_compute_instance.nat_instance.network_interface[0].nat_ip_address
    script_rev    = "v2"
  }

  # Нужен рабочий NAT, чтобы ClickHouse‑ВМ имела доступ в интернет
  depends_on = [null_resource.setup_nat]

  provisioner "local-exec" {
    working_dir = path.module

    command = <<-EOT
      set -e
      NAT_IP="${yandex_compute_instance.nat_instance.network_interface[0].nat_ip_address}"
      CLICKHOUSE_IP="${yandex_compute_instance.clickhouse.network_interface[0].ip_address}"
      SSH_KEY="${var.ssh_private_key_path}"

      echo "==> Копирую setup_clickhouse.sh на ВМ ClickHouse..."
      scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ProxyJump=ubuntu@"$NAT_IP" scripts/setup_clickhouse.sh ubuntu@"$CLICKHOUSE_IP":/home/ubuntu/

      echo "==> Запускаю setup_clickhouse.sh на ВМ ClickHouse..."
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ProxyJump=ubuntu@"$NAT_IP" ubuntu@"$CLICKHOUSE_IP" "bash ./setup_clickhouse.sh"
    EOT
  }
}

########################
## PROVISIONING: LOGBROKER-1
########################

resource "null_resource" "setup_logbroker_1" {
  triggers = {
    logbroker_ip = yandex_compute_instance.logbroker_1.network_interface[0].ip_address
    nat_ip       = yandex_compute_instance.nat_instance.network_interface[0].nat_ip_address
    clickhouse_ip = yandex_compute_instance.clickhouse.network_interface[0].ip_address
  }

  # Гарантируем, что NAT и ClickHouse настроены до запуска logbroker
  depends_on = [
    null_resource.setup_nat,
    null_resource.setup_clickhouse
  ]

  provisioner "local-exec" {
    working_dir = path.module

    command = <<-EOT
      set -e
      NAT_IP="${yandex_compute_instance.nat_instance.network_interface[0].nat_ip_address}"
      LOGBROKER_IP="${yandex_compute_instance.logbroker_1.network_interface[0].ip_address}"
      CLICKHOUSE_IP="${yandex_compute_instance.clickhouse.network_interface[0].ip_address}"
      SSH_KEY="${var.ssh_private_key_path}"

      echo "==> Копирую приложение logbroker на ВМ logbroker-1..."
      scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ProxyJump=ubuntu@"$NAT_IP" -r logbroker ubuntu@"$LOGBROKER_IP":/home/ubuntu/

      echo "==> Копирую setup_logbroker.sh на ВМ logbroker-1..."
      scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ProxyJump=ubuntu@"$NAT_IP" scripts/setup_logbroker.sh ubuntu@"$LOGBROKER_IP":/home/ubuntu/

      echo "==> Запускаю setup_logbroker.sh на ВМ logbroker-1..."
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ProxyJump=ubuntu@"$NAT_IP" ubuntu@"$LOGBROKER_IP" "CLICKHOUSE_HOST=$CLICKHOUSE_IP bash ./setup_logbroker.sh /home/ubuntu/logbroker"
    EOT
  }
}

########################
## PROVISIONING: LOGBROKER-2
########################

resource "null_resource" "setup_logbroker_2" {
  triggers = {
    logbroker_ip = yandex_compute_instance.logbroker_2.network_interface[0].ip_address
    nat_ip       = yandex_compute_instance.nat_instance.network_interface[0].nat_ip_address
    clickhouse_ip = yandex_compute_instance.clickhouse.network_interface[0].ip_address
  }

  depends_on = [
    null_resource.setup_nat,
    null_resource.setup_clickhouse
  ]

  provisioner "local-exec" {
    working_dir = path.module

    command = <<-EOT
      set -e
      NAT_IP="${yandex_compute_instance.nat_instance.network_interface[0].nat_ip_address}"
      LOGBROKER_IP="${yandex_compute_instance.logbroker_2.network_interface[0].ip_address}"
      CLICKHOUSE_IP="${yandex_compute_instance.clickhouse.network_interface[0].ip_address}"
      SSH_KEY="${var.ssh_private_key_path}"

      echo "==> Копирую приложение logbroker на ВМ logbroker-2..."
      scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ProxyJump=ubuntu@"$NAT_IP" -r logbroker ubuntu@"$LOGBROKER_IP":/home/ubuntu/

      echo "==> Копирую setup_logbroker.sh на ВМ logbroker-2..."
      scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ProxyJump=ubuntu@"$NAT_IP" scripts/setup_logbroker.sh ubuntu@"$LOGBROKER_IP":/home/ubuntu/

      echo "==> Запускаю setup_logbroker.sh на ВМ logbroker-2..."
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ProxyJump=ubuntu@"$NAT_IP" ubuntu@"$LOGBROKER_IP" "CLICKHOUSE_HOST=$CLICKHOUSE_IP bash ./setup_logbroker.sh /home/ubuntu/logbroker"
    EOT
  }
}

########################
## PROVISIONING: NGINX
########################

resource "null_resource" "setup_nginx" {
  triggers = {
    nginx_ip       = yandex_compute_instance.nginx.network_interface[0].nat_ip_address
    logbroker_1_ip = yandex_compute_instance.logbroker_1.network_interface[0].ip_address
    logbroker_2_ip = yandex_compute_instance.logbroker_2.network_interface[0].ip_address
  }

  # nginx должен настраиваться после того, как оба backend‑а подняты и настроены
  depends_on = [
    null_resource.setup_logbroker_1,
    null_resource.setup_logbroker_2
  ]

  provisioner "local-exec" {
    working_dir = path.module

    command = <<-EOT
      set -e
      NGINX_IP="${yandex_compute_instance.nginx.network_interface[0].nat_ip_address}"
      LOGBROKER_1_IP="${yandex_compute_instance.logbroker_1.network_interface[0].ip_address}"
      LOGBROKER_2_IP="${yandex_compute_instance.logbroker_2.network_interface[0].ip_address}"
      SSH_KEY="${var.ssh_private_key_path}"

      echo "==> Копирую setup_nginx.sh на ВМ nginx..."
      scp -i "$SSH_KEY" -o StrictHostKeyChecking=no scripts/setup_nginx.sh ubuntu@"$NGINX_IP":/home/ubuntu/

      echo "==> Запускаю setup_nginx.sh на ВМ nginx..."
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@"$NGINX_IP" "LOGBROKER_1=$LOGBROKER_1_IP LOGBROKER_2=$LOGBROKER_2_IP bash ./setup_nginx.sh"
    EOT
  }
}

########################
## OUTPUTS
########################

output "nginx_public_ip" {
  description = "Public IP address of nginx"
  value       = yandex_compute_instance.nginx.network_interface[0].nat_ip_address
}

output "nat_instance_public_ip" {
  description = "Public IP address of NAT instance (jump host)"
  value       = yandex_compute_instance.nat_instance.network_interface[0].nat_ip_address
}

output "logbroker_private_ips" {
  description = "Private IPs of logbroker backends"
  value = [
    yandex_compute_instance.logbroker_1.network_interface[0].ip_address,
    yandex_compute_instance.logbroker_2.network_interface[0].ip_address
  ]
}

output "clickhouse_private_ip" {
  description = "Private IP of ClickHouse instance"
  value       = yandex_compute_instance.clickhouse.network_interface[0].ip_address
}
