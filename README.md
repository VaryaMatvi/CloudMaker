# Cloudmaker 
Сервис для записи образов и создания виртуальных машин с FastAPI и запуском через docker-контейнер.

## 0. Перед запуском
В проекте реализовано базовое задание по созданию ВМ без графического интерфейса, а также пункты 1, 2, 5, 6, 7, 9, 11, 12:  
1\. HTTP API для управления ВМ и ресурсами   
2\. Cloud-init при запуске.   
5\. Приложение в контейнере управляет ВМ на хосте    
6\. Восстановление состояния   
7\. Возможность добавлять образы   
9\. Ограничение квоты   
11-12\. Скрипты для проверки и очистки после тестирования *(провалидированный нейрослоп для удобства тестирования)*

**Для корректной работы сервиса потребуется подготовить:**
1) Библиотеки   
```
sudo apt install qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst cloud-image-utils docker.io docker-compose-v2 python3-venv python3-libvirt
```
2) Добавить пользователя в группы libvirt и kvm
```
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm $USER      # выйти из сессии и войти снова
sudo chgrp libvirt /var/lib/libvirt/images && sudo chmod 775 /var/lib/libvirt/images
```
3) В программах требуется задать образ по умолчанию, которые используется для тестирования и если не задан пользовательский. Требуется файл /var/lib/libvirt/images/base-ubuntu-24.04.qcow2 (либо менять переменные окружения в check.sh и константы в main.py).
```
sudo wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img \
  -O /var/lib/libvirt/images/base-ubuntu-24.04.qcow2
```
4) Понадобится SSH ключ
```ssh-keygen -t ed25519```
5) В терминале проекта cloudmaker запущен докер-контейнер
```
sudo docker compose up -d --build
```

## 1. Запуск
Для быстрого тестирования достаточно запустить в терминале проекта:
```
./scripts/check.sh
```
и наблюдать за выводами.   
Дополнительно можно открыть Swagger в браузере http://127.0.0.1:8000/docs и создать образ или ВМ вручную.
>Поля, неиспользуемые при создании (например, в user-data может быть задан пользовательский конфиг, но по умолчанию None) нужно удалять!

Пример POST запроса на создание образа:
```
{
  "name": "ubuntu-24.04",
  "path": "/var/lib/libvirt/images/base-ubuntu-24.04.qcow2",
  "description": "Ubuntu 24.04 cloud-image"
}
```

Пример POST запроса на создание ВМ (ssh надо подставить свой)
```
{
  "name": "acloud-vm",
  "ssh_public_key": "ssh-ed25519 AAAA...",
  "vcpus": 1,
  "memory_mb": 1024,
  "disk_gb": 5,
  "username": "lazarevn",
  "image": "ubuntu-24.04"
}
```
>Созданные вручную ВМ скрипт cleanup.sh не удаляет. Можно убрать PREFIX test, тогда всё сотрёт 