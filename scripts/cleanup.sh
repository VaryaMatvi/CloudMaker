#!/bin/bash
# Удаляет следы тестирования CloudMaker: ВМ, диски, seed-ISO и записи реестра образов.
#
#   ./scripts/cleanup.sh               удалить всё с префиксом test-
#   ./scripts/cleanup.sh vm2 api-vm1   дополнительно удалить ВМ с этими именами

set -u

URI="qemu:///system"
API="${API:-http://127.0.0.1:8000}"
IMAGES_DIR="${IMAGES_DIR:-/var/lib/libvirt/images}"
PREFIX="${PREFIX:-test-}"

# Защита: с пустым префиксом шаблон "$PREFIX*" совпал бы со ВСЕМИ файлами
if [ -z "$PREFIX" ]; then
    echo "PREFIX не должен быть пустым" >&2
    exit 1
fi

vsh() { virsh -c "$URI" "$@"; }

# 1. ВМ: все с префиксом плюс имена из аргументов
names="$(vsh list --all --name | grep "^${PREFIX}") $*"
for name in $names; do
    echo "Удаляю ВМ: $name"
    vsh destroy "$name" >/dev/null 2>&1
    vsh undefine "$name" >/dev/null 2>&1
    rm -f "$IMAGES_DIR/$name.qcow2" "$IMAGES_DIR/$name.iso"
done

# 2. Файлы-сироты: диски и ISO с префиксом, у которых нет ВМ
rm -f "$IMAGES_DIR/$PREFIX"*.qcow2 "$IMAGES_DIR/$PREFIX"*.iso

# 3. Записи реестра образов с префиксом (через API: файл data/images.json принадлежит root)
if list="$(curl -sf "$API/images")"; then
    for img in $(python3 -c 'import sys, json; print("\n".join(i["name"] for i in json.load(sys.stdin)))' <<<"$list" | grep "^${PREFIX}"); do
        echo "Удаляю образ из реестра: $img"
        curl -s -o /dev/null -X DELETE "$API/images/$img"
    done
else
    echo "API недоступен: реестр образов не очищен (записи ${PREFIX}* удалите через DELETE /images/<имя>)"
fi

echo "Готово. Оставшиеся ВМ:"
vsh list --all