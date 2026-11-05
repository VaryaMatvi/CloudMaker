#!/bin/bash
# Проверка CloudMaker: проходит по всему реализованному функционалу.
# Запуск: ./scripts/check.sh   

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR/.."    # корень репозитория: отсюда работает docker compose

API="${API:-http://127.0.0.1:8000}"
IMAGES_DIR="${IMAGES_DIR:-/var/lib/libvirt/images}"
IMG_PATH="${IMG_PATH:-$IMAGES_DIR/base-ubuntu-24.04.qcow2}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
COMPOSE="${COMPOSE:-sudo docker compose}"
VM_MEM="${VM_MEM:-1024}"

VM_A="test-chk-a"
VM_B="test-chk-b"
IMG="test-img"
PASS=0
FAIL=0

# ---------- вывод и проверки ----------
section() { echo; echo "== $* =="; }
ok()   { echo "  [OK]   $*"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
die()  { echo "ОШИБКА: $*" >&2; exit 2; }

# HTTP-запрос: call МЕТОД ПУТЬ [JSON]. Результат в переменных CODE и BODY.
call() {
    local method=$1 path=$2 data=${3:-} out
    if [ -n "$data" ]; then
        out=$(curl -s -w '\n%{http_code}' -X "$method" "$API$path" -H 'Content-Type: application/json' -d "$data")
    else
        out=$(curl -s -w '\n%{http_code}' -X "$method" "$API$path")
    fi
    CODE=${out##*$'\n'}
    BODY=${out%$'\n'*}
}

# Достаёт значение из JSON в BODY: json 'd["state"]' (d - разобранный JSON)
json() {
    python3 -c 'import sys, json; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1" <<<"$BODY" 2>/dev/null
}

expect_code() { if [ "$CODE" = "$2" ]; then ok "$1 (HTTP $CODE)"; else bad "$1: ожидали HTTP $2, получили $CODE: $BODY"; fi; }
expect_eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: ожидали '$3', получили '$2'"; fi; }
assert()      { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# ---------- вспомогательные функции ----------
vsh()            { virsh -c qemu:///system "$@"; }
vm_state()       { vsh domstate "$1" 2>/dev/null; }
vm_absent()      { ! vsh dominfo "$1" >/dev/null 2>&1; }
vm_files_gone()  { [ ! -e "$IMAGES_DIR/$1.qcow2" ] && [ ! -e "$IMAGES_DIR/$1.iso" ]; }
vm_files_exist() { [ -e "$IMAGES_DIR/$1.qcow2" ] && [ -e "$IMAGES_DIR/$1.iso" ]; }
autostart_of()   { vsh dominfo "$1" 2>/dev/null | awk '/^Autostart:/ {print $2}'; }
no_test_files()  { ! ls "$IMAGES_DIR"/test-* >/dev/null 2>&1; }

in_images() {   # есть ли образ $IMG в GET /images
    call GET /images
    json '"\n".join(i["name"] for i in d)' | grep -qx "$IMG"
}

vmssh() {       # vmssh ПОЛЬЗОВАТЕЛЬ IP КОМАНДА...
    local user=$1 ip=$2; shift 2
    ssh -i "${SSH_KEY_FILE%.pub}" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=5 "$user@$ip" "$@"
}

wait_ip() {     # печатает IP ВМ из API; ждёт до 2 минут
    local i ip
    for i in $(seq 1 60); do
        call GET "/vms/$1"
        ip=$(json 'd["ips"][0] if d["ips"] else ""')
        if [ -n "$ip" ]; then echo "$ip"; return 0; fi
        sleep 2
    done
    return 1
}

wait_ssh() {    # wait_ssh ПОЛЬЗОВАТЕЛЬ IP: ждём, пока заработает sshd (до 90 с)
    local i
    for i in $(seq 1 45); do
        vmssh "$1" "$2" true 2>/dev/null && return 0
        sleep 2
    done
    return 1
}

wait_state() {  # wait_state ИМЯ СОСТОЯНИЕ СЕКУНДЫ
    local i
    for ((i = 0; i < $3; i += 2)); do
        [ "$(vm_state "$1")" = "$2" ] && return 0
        sleep 2
    done
    return 1
}

wait_api() {
    local i
    for i in $(seq 1 30); do
        curl -s -o /dev/null "$API/quota" && return 0
        sleep 2
    done
    return 1
}

# Тело запроса POST /vms: req ИМЯ ['"поле":значение,...']
req() { printf '{"name":"%s","ssh_public_key":"%s"%s}' "$1" "$KEY" "${2:+,$2}"; }

# То же, но со своим user_data (JSON собирает python, чтобы не возиться с экранированием)
req_ud() {      # req_ud ИМЯ ОБРАЗ
    python3 - "$1" "$2" "$KEY" "$VM_MEM" <<'EOF'
import json, sys
name, image, key, mem = sys.argv[1:5]
cfg = {"hostname": "chk-userdata", "manage_etc_hosts": True,
       "users": [{"name": "checker", "sudo": "ALL=(ALL) NOPASSWD:ALL",
                  "shell": "/bin/bash", "ssh_authorized_keys": [key]}],
       "write_files": [{"path": "/etc/cloudmaker-check", "content": "user-data-ok\n"}]}
print(json.dumps({"name": name, "image": image, "ssh_public_key": key, "memory_mb": int(mem),
                  "user_data": "#cloud-config\n" + json.dumps(cfg) + "\n"}))
EOF
}

# ---------- 0. Подготовка ----------
section "0. Подготовка"
for tool in curl python3 virsh ssh; do
    command -v "$tool" >/dev/null || die "не найдена программа '$tool'"
done
[ -f "$SSH_KEY_FILE" ]       || die "нет публичного ключа $SSH_KEY_FILE (ssh-keygen -t ed25519)"
[ -f "${SSH_KEY_FILE%.pub}" ] || die "нет приватного ключа ${SSH_KEY_FILE%.pub}"
[ -f "$IMG_PATH" ]           || die "нет образа $IMG_PATH (см. README)"
curl -s -o /dev/null "$API/quota" || die "API недоступен по адресу $API (sudo docker compose up -d --build)"
KEY=$(cat "$SSH_KEY_FILE")

trap 'exit 130' INT TERM
trap '"$DIR/cleanup.sh" >/dev/null 2>&1' EXIT    # страховка: уберёт тестовое даже при сбое
"$DIR/cleanup.sh" >/dev/null 2>&1
ok "окружение в порядке, остатки прошлых запусков убраны"

call GET /quota
USED_CPU0=$(json 'd["vcpus"]["used"]');   FREE_CPU=$(json 'd["vcpus"]["free"]')
USED_MEM0=$(json 'd["memory_mb"]["used"]'); FREE_MEM=$(json 'd["memory_mb"]["free"]')
if [ "$FREE_CPU" -lt 2 ] || [ "$FREE_MEM" -lt $((2 * VM_MEM)) ]; then
    die "в квоте мало места (свободно: $FREE_CPU vCPU, $FREE_MEM МБ; нужно 2 vCPU и $((2 * VM_MEM)) МБ). Удалите лишние ВМ или поднимите MAX_VCPUS/MAX_MEMORY_MB"
fi

# ---------- 1. Ошибки запросов ----------
section "1. Обработка ошибок (ничего не создаётся)"
call GET "/vms/test-chk-none";                                       expect_code "несуществующая ВМ" 404
call POST /vms "$(req Test_Bad)";                                    expect_code "недопустимое имя ВМ" 400
call POST /vms "$(req test-chk-x '"image":"test-no-such-image"')";   expect_code "незарегистрированный образ" 404

# ---------- 2. Квоты ----------
section "2. Квоты (пункт 9)"
if [ $((FREE_MEM + 1)) -le 16384 ]; then
    call POST /vms "$(req test-chk-q '"memory_mb":'"$((FREE_MEM + 1))")"
    expect_code "RAM сверх квоты" 409
    assert "при отказе ВМ не создана" vm_absent test-chk-q
else
    echo "  [SKIP] лимит RAM слишком велик для проверки (запрос не пройдёт валидацию)"
fi
if [ $((FREE_CPU + 1)) -le 8 ]; then
    call POST /vms "$(req test-chk-q '"vcpus":'"$((FREE_CPU + 1))")"
    expect_code "CPU сверх квоты" 409
else
    echo "  [SKIP] лимит CPU слишком велик для проверки"
fi

# ---------- 3. Реестр образов ----------
section "3. Реестр образов (пункт 7)"
call POST /images "{\"name\":\"$IMG\",\"path\":\"$IMG_PATH\",\"description\":\"check image\"}"
expect_code "регистрация образа" 201
assert "образ виден в GET /images" in_images
call POST /images "{\"name\":\"$IMG\",\"path\":\"$IMG_PATH\"}";                 expect_code "повторная регистрация" 409
call POST /images "{\"name\":\"test-bad\",\"path\":\"/tmp/no-such-file.qcow2\"}"; expect_code "несуществующий файл образа" 400

# ---------- 4. Создание ВМ ----------
section "4. Создание ВМ (пункты 1, 5, 6)"
call POST /vms "$(req "$VM_A" '"username":"checker","hostname":"chk-host","memory_mb":'"$VM_MEM")"
expect_code "создание $VM_A" 201
call POST /vms "$(req_ud "$VM_B" "$IMG")"
expect_code "создание $VM_B (образ из реестра + свой user_data)" 201
expect_eq "$VM_A запущена на хосте (virsh)" "$(vm_state "$VM_A")" "running"
expect_eq "$VM_B запущена на хосте (virsh)" "$(vm_state "$VM_B")" "running"
assert "файлы диска и seed-ISO созданы" vm_files_exist "$VM_A"
expect_eq "autostart включён" "$(autostart_of "$VM_A")" "enable"
call POST /vms "$(req "$VM_A")";   expect_code "повторное имя ВМ" 409
call GET /quota
expect_eq "квота учла новые ВМ (vCPU)" "$(json 'd["vcpus"]["used"]')" "$((USED_CPU0 + 2))"
expect_eq "квота учла новые ВМ (RAM)"  "$(json 'd["memory_mb"]["used"]')" "$((USED_MEM0 + 2 * VM_MEM))"

# ---------- 5. cloud-init ----------
section "5. cloud-init внутри ВМ (пункты 2, 7); ждём загрузку, до пары минут"
IP_A=$(wait_ip "$VM_A"); IP_B=$(wait_ip "$VM_B")
if [ -n "$IP_A" ] && wait_ssh checker "$IP_A"; then
    ok "$VM_A: получила адрес $IP_A, SSH по ключу работает"
    out=$(vmssh checker "$IP_A" 'hostname; whoami; sudo -n true && echo sudo-ok')
    expect_eq "hostname из запроса" "$(sed -n 1p <<<"$out")" "chk-host"
    expect_eq "username из запроса" "$(sed -n 2p <<<"$out")" "checker"
    expect_eq "sudo без пароля"     "$(sed -n 3p <<<"$out")" "sudo-ok"
else
    bad "$VM_A: нет адреса или SSH не отвечает (смотрите: virsh console $VM_A)"
fi
if [ -n "$IP_B" ] && wait_ssh checker "$IP_B"; then
    out=$(vmssh checker "$IP_B" 'hostname; cat /etc/cloudmaker-check')
    expect_eq "$VM_B: hostname из своего user_data" "$(sed -n 1p <<<"$out")" "chk-userdata"
    expect_eq "$VM_B: write_files из своего user_data" "$(sed -n 2p <<<"$out")" "user-data-ok"
else
    bad "$VM_B: нет адреса или SSH не отвечает (смотрите: virsh console $VM_B)"
fi

# ---------- 6. Перезапуск контейнера ----------
section "6. Восстановление состояния после перезапуска (пункты 5, 6)"
if [ "${SKIP_RESTART:-0}" = 1 ]; then
    echo "  [SKIP] SKIP_RESTART=1"
elif $COMPOSE restart >/dev/null 2>&1 && wait_api; then
    ok "контейнер перезапущен, API снова отвечает"
    call GET "/vms/$VM_A"; expect_code "$VM_A видна после перезапуска" 200
    call GET "/vms/$VM_B"; expect_code "$VM_B видна после перезапуска" 200
    assert "образ остался в реестре" in_images
    expect_eq "ВМ продолжает работать" "$(vm_state "$VM_A")" "running"
    assert "SSH-доступ к ВМ не потерян" vmssh checker "$IP_A" true
else
    bad "не удалось перезапустить контейнер командой: $COMPOSE restart"
fi

# ---------- 7. Управление ----------
section "7. Остановка и запуск (пункты 1, 6)"
call POST "/vms/$VM_A/stop";                expect_code "мягкая остановка" 200
assert "ВМ выключилась сама (virsh)" wait_state "$VM_A" "shut off" 60
expect_eq "autostart выключен после остановки" "$(autostart_of "$VM_A")" "disable"
call POST "/vms/$VM_A/stop";                expect_code "повторная остановка" 409
call POST "/vms/$VM_A/start";               expect_code "запуск" 200
expect_eq "ВМ запущена (virsh)" "$(vm_state "$VM_A")" "running"
expect_eq "autostart снова включён" "$(autostart_of "$VM_A")" "enable"
call POST "/vms/$VM_A/stop?force=true";     expect_code "жёсткая остановка" 200
expect_eq "ВМ остановлена сразу (virsh)" "$(vm_state "$VM_A")" "shut off"
call POST "/vms/$VM_A/start";               expect_code "повторный запуск" 200

# ---------- 8. Удаление и очистка ----------
section "8. Удаление и скрипт очистки (пункты 1, 12)"
call DELETE "/vms/$VM_A";                   expect_code "удаление $VM_A через API" 200
assert "ВМ исчезла из libvirt" vm_absent "$VM_A"
assert "файлы диска и ISO удалены" vm_files_gone "$VM_A"
"$DIR/cleanup.sh" >/dev/null 2>&1
assert "cleanup.sh: ВМ $VM_B удалена" vm_absent "$VM_B"
assert "cleanup.sh: тестовых файлов в $IMAGES_DIR нет" no_test_files
if in_images; then bad "cleanup.sh: образ $IMG остался в реестре"; else ok "cleanup.sh: образ $IMG убран из реестра"; fi
call GET /quota
expect_eq "квота вернулась к исходной (RAM)" "$(json 'd["memory_mb"]["used"]')" "$USED_MEM0"

echo
echo "Итого: успешно $PASS, ошибок $FAIL"
exit $((FAIL > 0))