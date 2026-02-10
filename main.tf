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
