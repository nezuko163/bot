#!/bin/bash
# ============================================================
#  AmneziaWG Manager — интерактивное управление VPN сервером
#  Требования: fzf, awg, awg-quick, iptables, qrencode
# ============================================================

set -euo pipefail

# ──────────────────────────────────────────
# Конфигурация
# ──────────────────────────────────────────
DIR="/etc/amnezia/amneziawg"          # Папка с конфигами
INTERFACE="awg0"                       # Имя интерфейса
CONF="$DIR/${INTERFACE}.conf"          # Конфиг сервера
CLIENTS_DIR="$DIR/clients"            # Папка с конфигами клиентов
SERVER_VPN_IP="10.8.0.1"              # IP сервера в VPN-сети
VPN_SUBNET="10.8.0.0/24"             # Подсеть VPN
DNS="1.1.1.1, 8.8.8.8"               # DNS для клиентов

# ──────────────────────────────────────────
# Цвета и утилиты
# ──────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: скрипт нужно запускать от root (sudo)${RESET}"
    exit 1
  fi
}

check_deps() {
  local missing=()
  for cmd in fzf awg awg-quick iptables sysctl; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}Не найдены зависимости: ${missing[*]}${RESET}"
    echo -e "${DIM}Установите их и повторите запуск${RESET}"
    exit 1
  fi
}

header() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║       🛡️  AmneziaWG Manager              ║"
  echo "  ╚══════════════════════════════════════════╝"
  echo -e "${RESET}"
}

pause() {
  echo -e "${DIM}  Нажмите Enter для продолжения...${RESET}"
  read -r
}

# Следующий свободный IP в подсети VPN
next_client_ip() {
  local used_ips
  used_ips=$(grep -h "AllowedIPs" "$CONF" 2>/dev/null | grep -oP '10\.8\.0\.\K\d+' || true)
  for i in $(seq 2 254); do
    if ! echo "$used_ips" | grep -qx "$i"; then
      echo "10.8.0.$i"
      return
    fi
  done
  echo ""
}

# Получить публичный IP сервера
server_public_ip() {
  curl -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
}

# Получить текущий порт из конфига
server_port() {
  grep "^ListenPort" "$CONF" 2>/dev/null | awk '{print $3}' || echo "51820"
}

# ──────────────────────────────────────────
# МЕНЮ: Настроить сервер
# ──────────────────────────────────────────
server_menu() {
  while true; do
    local STATUS FWD SERVER_STATUS FWD_STATUS ACTION
    STATUS=$(awg show "$INTERFACE" 2>/dev/null | grep "listening port" | awk '{print $3}')
    if [ -n "$STATUS" ]; then
      SERVER_STATUS="${GREEN}🟢 Запущен (порт $STATUS)${RESET}"
    else
      SERVER_STATUS="${RED}🔴 Остановлен${RESET}"
    fi

    FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
    if [ "$FWD" = "1" ]; then
      FWD_STATUS="${GREEN}🟢 Включён${RESET}"
    else
      FWD_STATUS="${RED}🔴 Выключен${RESET}"
    fi

    header
    echo -e "  Сервер:        $SERVER_STATUS"
    echo -e "  IP Forwarding: $FWD_STATUS"
    echo ""

    ACTION=$(printf "▶️  Запустить\n🔄 Перезапустить\n⏹️  Остановить\n📊 Статус и клиенты\n🔧 Починить (forwarding + firewall)\n⬅️  Назад" | \
      fzf --height=12 --border --no-info \
          --pointer="➤" \
          --prompt="  Действие: ")

    case "$ACTION" in
      "▶️  Запустить")
        header
        echo -e "${CYAN}▶️  Запуск сервера...${RESET}"
        echo ""
        sysctl -w net.ipv4.ip_forward=1
        awg-quick up "$CONF" 2>&1
        echo ""
        echo -e "${GREEN}✅ Сервер запущен${RESET}"
        echo ""
        pause
        ;;

      "🔄 Перезапустить")
        header
        echo -e "${CYAN}🔄 Перезапуск сервера...${RESET}"
        echo ""
        awg-quick down "$CONF" 2>&1 || true
        sleep 1
        sysctl -w net.ipv4.ip_forward=1
        awg-quick up "$CONF" 2>&1
        echo ""
        echo -e "${GREEN}✅ Перезапущен${RESET}"
        echo ""
        pause
        ;;

      "⏹️  Остановить")
        header
        echo -e "${YELLOW}⏹️  Остановка сервера...${RESET}"
        echo ""
        awg-quick down "$CONF" 2>&1
        echo ""
        echo -e "${YELLOW}⏹️  Сервер остановлен${RESET}"
        echo ""
        pause
        ;;

      "📊 Статус и клиенты")
        header
        echo -e "${BOLD}📊 Статус сервера:${RESET}"
        echo "  ────────────────────────────────────────"
        awg show 2>/dev/null || echo "  Сервер не запущен"
        echo "  ────────────────────────────────────────"
        echo ""
        echo -e "  🔒 IP Forwarding: $(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
        echo ""
        echo -e "  🔥 NAT правила:"
        iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | sed 's/^/  /'
        echo ""
        pause
        ;;

      "🔧 Починить (forwarding + firewall)")
        header
        echo -e "${CYAN}🔧 Применяю исправления...${RESET}"
        echo ""

        sysctl -w net.ipv4.ip_forward=1
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-vpn.conf
        sysctl -p /etc/sysctl.d/99-vpn.conf &>/dev/null
        echo -e "${GREEN}  ✅ IP Forwarding включён${RESET}"

        local PORT
        PORT=$(server_port)
        iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || \
          iptables -A INPUT -p udp --dport "$PORT" -j ACCEPT
        iptables -C INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
          iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

        # NAT
        local IFACE
        IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
        iptables -t nat -C POSTROUTING -s "$VPN_SUBNET" -o "$IFACE" -j MASQUERADE 2>/dev/null || \
          iptables -t nat -A POSTROUTING -s "$VPN_SUBNET" -o "$IFACE" -j MASQUERADE
        echo -e "${GREEN}  ✅ Порт $PORT открыт, NAT настроен${RESET}"

        if command -v netfilter-persistent &>/dev/null; then
          netfilter-persistent save 2>/dev/null
          echo -e "${GREEN}  ✅ Правила сохранены${RESET}"
        fi

        awg-quick down "$CONF" 2>/dev/null || true
        sleep 1
        awg-quick up "$CONF" 2>&1
        echo ""
        echo -e "${GREEN}  ✅ Готово!${RESET}"
        echo ""
        pause
        ;;

      "⬅️  Назад"|"")
        break
        ;;
    esac
  done
}

# ──────────────────────────────────────────
# МЕНЮ: Добавить клиента
# ──────────────────────────────────────────
add_client() {
  header
  echo -e "${BOLD}  ➕ Добавление нового клиента${RESET}"
  echo ""

  # Имя клиента
  echo -e "  ${DIM}Введите имя клиента (например: phone, laptop, work):${RESET}"
  echo -n "  > "
  read -r CLIENT_NAME

  if [[ -z "$CLIENT_NAME" ]]; then
    echo -e "${RED}  Имя не может быть пустым${RESET}"
    pause
    return
  fi

  # Проверка уникальности
  if [[ -f "$CLIENTS_DIR/${CLIENT_NAME}.conf" ]]; then
    echo -e "${RED}  Клиент '$CLIENT_NAME' уже существует!${RESET}"
    pause
    return
  fi

  mkdir -p "$CLIENTS_DIR"

  # Генерация ключей клиента
  local CLIENT_PRIVKEY CLIENT_PUBKEY CLIENT_PSK CLIENT_IP
  CLIENT_PRIVKEY=$(awg genkey)
  CLIENT_PUBKEY=$(echo "$CLIENT_PRIVKEY" | awg pubkey)
  CLIENT_PSK=$(awg genpsk)
  CLIENT_IP=$(next_client_ip)

  if [[ -z "$CLIENT_IP" ]]; then
    echo -e "${RED}  Нет свободных IP адресов в подсети!${RESET}"
    pause
    return
  fi

  local SERVER_PUBKEY SERVER_IP SERVER_PORT
  SERVER_PUBKEY=$(grep "^PrivateKey" "$CONF" | awk '{print $3}' | awg pubkey)
  SERVER_IP=$(server_public_ip)
  SERVER_PORT=$(server_port)

  # ── Читаем AWG-параметры обфускации из серверного конфига ──────
  # AmneziaVPN требует эти параметры в конфиге клиента,
  # иначе распознаёт его как обычный WireGuard и не подключается
  local JC JMIN JMAX S1 S2 H1 H2 H3 H4
  JC=$(grep    "^Jc"   "$CONF" 2>/dev/null | awk '{print $3}' || echo "4")
  JMIN=$(grep  "^Jmin" "$CONF" 2>/dev/null | awk '{print $3}' || echo "40")
  JMAX=$(grep  "^Jmax" "$CONF" 2>/dev/null | awk '{print $3}' || echo "70")
  S1=$(grep    "^S1"   "$CONF" 2>/dev/null | awk '{print $3}' || echo "0")
  S2=$(grep    "^S2"   "$CONF" 2>/dev/null | awk '{print $3}' || echo "0")
  H1=$(grep    "^H1"   "$CONF" 2>/dev/null | awk '{print $3}' || echo "1")
  H2=$(grep    "^H2"   "$CONF" 2>/dev/null | awk '{print $3}' || echo "2")
  H3=$(grep    "^H3"   "$CONF" 2>/dev/null | awk '{print $3}' || echo "3")
  H4=$(grep    "^H4"   "$CONF" 2>/dev/null | awk '{print $3}' || echo "4")

  # Конфиг клиента — с AWG-параметрами обфускации
  cat > "$CLIENTS_DIR/${CLIENT_NAME}.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = ${CLIENT_IP}/32
DNS = $DNS
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $SERVER_PUBKEY
PresharedKey = $CLIENT_PSK
Endpoint = ${SERVER_IP}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

  # Добавляем пира в серверный конфиг
  cat >> "$CONF" <<EOF

# Client: $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUBKEY
PresharedKey = $CLIENT_PSK
AllowedIPs = ${CLIENT_IP}/32
EOF

  # Применяем без перезапуска, если сервер запущен
  if awg show "$INTERFACE" &>/dev/null; then
    awg set "$INTERFACE" peer "$CLIENT_PUBKEY" \
      preshared-key <(echo "$CLIENT_PSK") \
      allowed-ips "${CLIENT_IP}/32" 2>/dev/null || true
    echo -e "${GREEN}  ✅ Клиент добавлен на живой сервер${RESET}"
  fi

  echo ""
  echo -e "${GREEN}  ✅ Клиент '${BOLD}$CLIENT_NAME${RESET}${GREEN}' создан!${RESET}"
  echo -e "  📍 VPN IP: ${CYAN}$CLIENT_IP${RESET}"
  echo -e "  📁 Конфиг: ${DIM}$CLIENTS_DIR/${CLIENT_NAME}.conf${RESET}"
  echo ""

  # ── Ссылка для подключения AmneziaVPN ──────────────────────────
  # Формат: vpn://base64(конфиг)?name=urlencoded_name
  # Именно этот формат принимает AmneziaVPN при вставке ссылки
  local VPN_LINK ENCODED_NAME CONF_B64
  ENCODED_NAME=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$CLIENT_NAME" 2>/dev/null || echo "$CLIENT_NAME")
  CONF_B64=$(base64 -w 0 < "$CLIENTS_DIR/${CLIENT_NAME}.conf")
  VPN_LINK="vpn://${CONF_B64}?name=${ENCODED_NAME}"
  if [[ -z "$CONF_B64" ]]; then
    VPN_LINK="(ошибка генерации ссылки)"
  fi
  echo -e "  ${BOLD}🔗 Ссылка для подключения (AmneziaVPN):${RESET}"
  echo ""
  echo -e "  ${CYAN}$VPN_LINK${RESET}"
  echo ""
  echo -e "  ${DIM}Скопируй ссылку и открой в приложении AmneziaVPN,${RESET}"
  echo -e "  ${DIM}или отправь её на устройство клиента.${RESET}"
  echo ""

  # ── QR-код ссылки ──────────────────────────────────────────────
  if command -v qrencode &>/dev/null; then
    echo -e "  ${BOLD}📱 QR-код ссылки (сканируй в AmneziaVPN):${RESET}"
    echo ""
    echo -n "$VPN_LINK" | qrencode -t ansiutf8
    echo ""
  else
    echo -e "  ${DIM}(установите qrencode для отображения QR-кода: apt install qrencode)${RESET}"
    echo ""
  fi

  echo -e "  ${DIM}Содержимое конфига:${RESET}"
  echo "  ────────────────────────────────────────"
  cat "$CLIENTS_DIR/${CLIENT_NAME}.conf" | sed 's/^/  /'
  echo "  ────────────────────────────────────────"
  echo ""
  pause
}

# ──────────────────────────────────────────
# МЕНЮ: Список клиентов
# ──────────────────────────────────────────
list_clients() {
  header
  echo -e "${BOLD}  📋 Список клиентов${RESET}"
  echo ""

  if [[ ! -d "$CLIENTS_DIR" ]] || [[ -z "$(ls -A "$CLIENTS_DIR" 2>/dev/null)" ]]; then
    echo -e "  ${YELLOW}Клиентов пока нет${RESET}"
    echo ""
    pause
    return
  fi

  local clients
  clients=$(ls "$CLIENTS_DIR"/*.conf 2>/dev/null | xargs -I{} basename {} .conf)

  if [[ -z "$clients" ]]; then
    echo -e "  ${YELLOW}Клиентов пока нет${RESET}"
    echo ""
    pause
    return
  fi

  echo -e "  ${DIM}┌─────────────────────────────────────────────────────┐${RESET}"
  printf "  ${DIM}│${RESET}  %-20s %-16s %-12s ${DIM}│${RESET}\n" "Имя" "VPN IP" "Статус"
  echo -e "  ${DIM}├─────────────────────────────────────────────────────┤${RESET}"

  while IFS= read -r name; do
    local conf="$CLIENTS_DIR/${name}.conf"
    local ip
    ip=$(grep "^Address" "$conf" 2>/dev/null | awk '{print $3}' | cut -d'/' -f1 || echo "—")

    # Проверяем активность через awg show
    local pubkey status
    pubkey=$(grep "^PrivateKey" "$conf" 2>/dev/null | awk '{print $3}' | awg pubkey 2>/dev/null || echo "")
    if [[ -n "$pubkey" ]] && awg show "$INTERFACE" peers 2>/dev/null | grep -q "$pubkey"; then
      local last_handshake
      last_handshake=$(awg show "$INTERFACE" latest-handshakes 2>/dev/null | grep "$pubkey" | awk '{print $2}' || echo "0")
      local now
      now=$(date +%s)
      if [[ $((now - last_handshake)) -lt 180 ]]; then
        status="${GREEN}🟢 Онлайн${RESET}"
      else
        status="${YELLOW}🟡 Был онлайн${RESET}"
      fi
    else
      status="${DIM}⚫ Не подключён${RESET}"
    fi

    printf "  ${DIM}│${RESET}  %-20s %-16s " "$name" "$ip"
    echo -e "$status  ${DIM}│${RESET}"
  done <<< "$clients"

  echo -e "  ${DIM}└─────────────────────────────────────────────────────┘${RESET}"
  echo ""
  echo -e "  Всего клиентов: ${CYAN}$(echo "$clients" | wc -l)${RESET}"
  echo ""

  # Предложить показать конфиг/QR конкретного клиента
  local SELECTED
  SELECTED=$(echo "$clients" | fzf \
    --height=10 --border --no-info \
    --pointer="➤" \
    --prompt="  Выберите клиента для просмотра конфига (Esc — выход): " \
    --bind "esc:abort" 2>/dev/null || true)

  if [[ -n "$SELECTED" ]]; then
    header
    echo -e "${BOLD}  📄 Конфиг клиента: ${CYAN}$SELECTED${RESET}"
    echo ""
    echo "  ────────────────────────────────────────"
    cat "$CLIENTS_DIR/${SELECTED}.conf" | sed 's/^/  /'
    echo "  ────────────────────────────────────────"
    echo ""
    if command -v qrencode &>/dev/null; then
      local SEL_ENC_NAME SEL_CONF_B64 SEL_VPN_LINK
      SEL_ENC_NAME=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$SELECTED" 2>/dev/null || echo "$SELECTED")
      SEL_CONF_B64=$(base64 -w 0 < "$CLIENTS_DIR/${SELECTED}.conf")
      SEL_VPN_LINK="vpn://${SEL_CONF_B64}?name=${SEL_ENC_NAME}"
      echo -e "  ${BOLD}🔗 Ссылка для подключения:${RESET}"
      echo ""
      echo -e "  ${CYAN}$SEL_VPN_LINK${RESET}"
      echo ""
      echo -e "  ${BOLD}📱 QR-код ссылки (сканируй в AmneziaVPN):${RESET}"
      echo ""
      echo -n "$SEL_VPN_LINK" | qrencode -t ansiutf8
      echo ""
    fi
    pause
  fi
}

# ──────────────────────────────────────────
# МЕНЮ: Удалить всех клиентов
# ──────────────────────────────────────────
delete_all_clients() {
  header
  echo -e "${BOLD}${RED}  🗑️  Удаление ВСЕХ клиентов${RESET}"
  echo ""

  if [[ ! -d "$CLIENTS_DIR" ]] || [[ -z "$(ls -A "$CLIENTS_DIR" 2>/dev/null)" ]]; then
    echo -e "  ${YELLOW}Клиентов нет — нечего удалять${RESET}"
    echo ""
    pause
    return
  fi

  local count
  count=$(ls "$CLIENTS_DIR"/*.conf 2>/dev/null | wc -l)

  echo -e "  ${YELLOW}⚠️  Будет удалено клиентов: ${BOLD}$count${RESET}"
  echo ""
  echo -e "  ${RED}Это действие необратимо!${RESET}"
  echo ""

  local CONFIRM
  CONFIRM=$(printf "❌ Нет, отмена\n✅ Да, удалить всех клиентов" | \
    fzf --height=6 --border --no-info \
        --pointer="➤" \
        --prompt="  Подтвердите: ")

  if [[ "$CONFIRM" != "✅ Да, удалить всех клиентов" ]]; then
    echo ""
    echo -e "  ${GREEN}Отменено${RESET}"
    echo ""
    pause
    return
  fi

  echo ""
  echo -e "${CYAN}  Удаляю клиентов...${RESET}"
  echo ""

  # Удаляем пиров из живого интерфейса
  while IFS= read -r conf_file; do
    local name
    name=$(basename "$conf_file" .conf)
    local privkey pubkey
    privkey=$(grep "^PrivateKey" "$conf_file" 2>/dev/null | awk '{print $3}' || true)
    if [[ -n "$privkey" ]]; then
      pubkey=$(echo "$privkey" | awg pubkey 2>/dev/null || true)
      if [[ -n "$pubkey" ]]; then
        awg set "$INTERFACE" peer "$pubkey" remove 2>/dev/null || true
      fi
    fi
    echo -e "  ${DIM}Удалён: $name${RESET}"
  done < <(ls "$CLIENTS_DIR"/*.conf 2>/dev/null)

  # Удаляем файлы клиентов
  rm -f "$CLIENTS_DIR"/*.conf

  # Чистим серверный конфиг — удаляем все [Peer] секции
  if [[ -f "$CONF" ]]; then
    # Сохраняем только [Interface] секцию
    local iface_section
    iface_section=$(awk '/^\[Interface\]/{p=1} /^\[Peer\]/{p=0} p' "$CONF")
    echo "$iface_section" > "$CONF"
  fi

  echo ""
  echo -e "${GREEN}  ✅ Все клиенты удалены${RESET}"
  echo ""
  pause
}

# ──────────────────────────────────────────
# Главное меню
# ──────────────────────────────────────────
main_menu() {
  while true; do
    local CLIENT_COUNT="0"
    [[ -d "$CLIENTS_DIR" ]] && CLIENT_COUNT=$(ls "$CLIENTS_DIR"/*.conf 2>/dev/null | wc -l || echo 0)

    local SERVER_STATUS
    if awg show "$INTERFACE" &>/dev/null 2>&1; then
      local PORT
      PORT=$(awg show "$INTERFACE" 2>/dev/null | grep "listening port" | awk '{print $3}')
      SERVER_STATUS="🟢 Запущен (порт ${PORT:-?})"
    else
      SERVER_STATUS="🔴 Остановлен"
    fi

    header
    echo -e "  ${DIM}Сервер: $SERVER_STATUS  │  Клиентов: $CLIENT_COUNT${RESET}"
    echo ""

    local ACTION
    ACTION=$(printf "⚙️  Настроить сервер\n➕ Добавить клиента\n📋 Список клиентов\n🗑️  Удалить всех клиентов\n🚪 Выход" | \
      fzf --height=12 --border --no-info \
          --pointer="➤" \
          --prompt="  Выберите действие: ")

    case "$ACTION" in
      "⚙️  Настроить сервер")
        server_menu
        ;;
      "➕ Добавить клиента")
        add_client
        ;;
      "📋 Список клиентов")
        list_clients
        ;;
      "🗑️  Удалить всех клиентов")
        delete_all_clients
        ;;
      "🚪 Выход"|"")
        header
        echo -e "  ${DIM}До свидания!${RESET}"
        echo ""
        exit 0
        ;;
    esac
  done
}

# ──────────────────────────────────────────
# Точка входа
# ──────────────────────────────────────────
check_root
check_deps
main_menu