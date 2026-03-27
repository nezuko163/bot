cat > /usr/local/bin/amnezia << 'EOF'
#!/bin/bash
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

DIR="/etc/amnezia/amneziawg"

pause() {
  read -p "Нажми Enter..."
  clear
}

header() {
  clear
  echo "╔══════════════════════════════╗"
  echo "║      AMNEZIA VPN MANAGER     ║"
  echo "╚══════════════════════════════╝"
}

get_clients() {
  for f in $DIR/client_*_displayname.txt; do
    [ -f "$f" ] || continue
    NAME=$(cat "$f")
    SAFE=$(basename "$f" _displayname.txt)
    IP=$(grep "^Address" "$DIR/${SAFE}.conf" 2>/dev/null | awk '{print $3}' | cut -d'/' -f1)
    echo "${SAFE}|${NAME}|${IP:-none}"
  done
}

client_actions() {
  SAFE_NAME="$1"
  DISPLAY_NAME=$(cat $DIR/${SAFE_NAME}_displayname.txt 2>/dev/null)
  PUBLIC_KEY=$(cat $DIR/${SAFE_NAME}_public.key 2>/dev/null)

  while true; do
    ACTION=$(printf "📱 Получить ссылку\n👁️ Показать данные\n📄 Показать конфиг\n🗑️ Удалить клиента\n⬅️ Назад" | \
      fzf --height=12 --border --no-info \
          --header="Клиент: $DISPLAY_NAME" \
          --pointer="➤")

    case "$ACTION" in
      "📱 Получить ссылку")
        CONF_B64=$(base64 < $DIR/${SAFE_NAME}.conf | tr -d '\n')
        ENCODED_NAME=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$DISPLAY_NAME")
        clear
        echo "🔗 VPN ссылка:"
        echo ""
        echo "vpn://${CONF_B64}?name=${ENCODED_NAME}"
        echo ""
        read -p "Enter..."
        ;;

      "👁️ Показать данные")
        IP=$(awg show awg0 allowed-ips 2>/dev/null | grep "$PUBLIC_KEY" | awk '{print $2}')
        ENDPOINT=$(awg show awg0 endpoints 2>/dev/null | grep "$PUBLIC_KEY" | awk '{print $2}')
        HANDSHAKE=$(awg show awg0 latest-handshakes 2>/dev/null | grep "$PUBLIC_KEY" | awk '{print $2}')
        TRANSFER=$(awg show awg0 transfer 2>/dev/null | grep "$PUBLIC_KEY" | awk '{print $2 " ↓ / " $3 " ↑"}')
        clear
        echo "══════════ 👤 КЛИЕНТ ══════════"
        echo "Имя:        $DISPLAY_NAME"
        echo "IP:         ${IP:-не подключён}"
        echo "Endpoint:   ${ENDPOINT:-—}"
        echo "Handshake:  ${HANDSHAKE:-—}"
        echo "Трафик:     ${TRANSFER:-—}"
        echo ""
        echo "🔑 Public key:"
        echo "$PUBLIC_KEY"
        echo ""
        read -p "Enter..."
        ;;

      "📄 Показать конфиг")
        clear
        cat $DIR/${SAFE_NAME}.conf
        echo ""
        read -p "Enter..."
        ;;

      "🗑️ Удалить клиента")
        read -p "Удалить '$DISPLAY_NAME'? (y/N): " CONFIRM
        if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
          awg set awg0 peer $PUBLIC_KEY remove 2>/dev/null
          awg-quick save $DIR/awg0.conf 2>/dev/null
          rm -f $DIR/${SAFE_NAME}_displayname.txt \
                $DIR/${SAFE_NAME}_public.key \
                $DIR/${SAFE_NAME}_private.key \
                $DIR/${SAFE_NAME}.conf
          clear
          echo "✅ Удалён: $DISPLAY_NAME"
          read -p "Enter..."
          break
        fi
        ;;

      "⬅️ Назад"|"")
        break
        ;;
    esac
  done
}

server_menu() {
  while true; do
    # Получаем статус
    STATUS=$(awg show awg0 2>/dev/null | grep "listening port" | awk '{print $3}')
    if [ -n "$STATUS" ]; then
      SERVER_STATUS="🟢 Запущен (порт $STATUS)"
    else
      SERVER_STATUS="🔴 Остановлен"
    fi

    # IP forwarding
    FWD=$(sysctl -n net.ipv4.ip_forward)
    if [ "$FWD" = "1" ]; then
      FWD_STATUS="🟢 Включён"
    else
      FWD_STATUS="🔴 Выключен"
    fi

    header
    echo "  Сервер:       $SERVER_STATUS"
    echo "  IP Forwarding: $FWD_STATUS"
    echo ""

    ACTION=$(printf "▶️  Запустить\n🔄 Перезапустить\n⏹️  Остановить\n📊 Статус и клиенты\n🔧 Починить (forwarding + firewall)\n⬅️  Назад" | \
      fzf --height=12 --border --no-info \
          --pointer="➤")

    case "$ACTION" in
      "▶️  Запустить")
        header
        echo "▶️  Запуск сервера..."
        echo ""
        # Включаем forwarding
        sysctl -w net.ipv4.ip_forward=1
        # Запускаем туннель
        awg-quick up $DIR/awg0.conf 2>&1
        echo ""
        pause
        ;;

      "🔄 Перезапустить")
        header
        echo "🔄 Перезапуск сервера..."
        echo ""
        awg-quick down $DIR/awg0.conf 2>&1
        sleep 1
        sysctl -w net.ipv4.ip_forward=1
        awg-quick up $DIR/awg0.conf 2>&1
        echo ""
        pause
        ;;

      "⏹️  Остановить")
        header
        echo "⏹️  Остановка сервера..."
        echo ""
        awg-quick down $DIR/awg0.conf 2>&1
        echo ""
        pause
        ;;

      "📊 Статус и клиенты")
        header
        echo "📊 Статус сервера:"
        echo "--------------------------------"
        awg show 2>/dev/null || echo "Сервер не запущен"
        echo "--------------------------------"
        echo ""
        echo "🔒 IP Forwarding: $(sysctl -n net.ipv4.ip_forward)"
        echo ""
        echo "🔥 NAT правила:"
        iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null
        echo ""
        pause
        ;;

      "🔧 Починить (forwarding + firewall)")
        header
        echo "🔧 Применяю исправления..."
        echo ""

        # IP forwarding
        sysctl -w net.ipv4.ip_forward=1
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-vpn.conf
        sysctl -p /etc/sysctl.d/99-vpn.conf
        echo "✅ IP Forwarding включён"

        # Firewall
        iptables -A INPUT -p udp --dport 51820 -j ACCEPT 2>/dev/null
        iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
        echo "✅ Порт 51820 открыт"

        # Сохраняем правила
        netfilter-persistent save 2>/dev/null
        echo "✅ Правила сохранены"

        # Перезапускаем туннель
        awg-quick down $DIR/awg0.conf 2>/dev/null
        sleep 1
        awg-quick up $DIR/awg0.conf 2>&1
        echo ""
        echo "✅ Готово!"
        echo ""
        pause
        ;;

      "⬅️  Назад"|"")
        break
        ;;
    esac
  done
}

while true; do
  header

  CHOICE=$(printf "➕ Добавить клиента\n📋 Список клиентов\n🗑️ Удалить клиента\n🖥️  Управление сервером\n❌ Выход" | \
    fzf --height=10 --border \
        --color=bg+:#1e1e1e,fg+:#ffffff,hl:#00ffcc \
        --pointer="➤" --marker="✓" \
        --no-info)

  case "$CHOICE" in
    "➕ Добавить клиента")
      header
      awg-add-client
      pause
      ;;

    "📋 Список клиентов")
      CLIENT=$(get_clients | \
        fzf --height=15 --border --no-info \
            --delimiter="|" \
            --with-nth=2,3 \
            --pointer="➤" \
            --header="Выбери клиента")
      [ -z "$CLIENT" ] && continue
      SAFE_NAME=$(echo "$CLIENT" | awk -F'|' '{print $1}')
      client_actions "$SAFE_NAME"
      ;;
      
    "🗑️ Удалить клиента")
      CLIENT=$(get_clients | \
        fzf --height=15 --border \
            --delimiter="|" \
            --with-nth=1,2 \
            --no-info)
      [ -z "$CLIENT" ] && continue
      SAFE=$(echo "$CLIENT" | awk -F'|' '{print $3}' | xargs)
      DISPLAY=$(echo "$CLIENT" | awk -F'|' '{print $1}' | xargs)
      PUB=$(cat $DIR/${SAFE}_public.key)
      awg set awg0 peer $PUB remove
      awg-quick save $DIR/awg0.conf
      rm -f $DIR/${SAFE}_*
      header
      echo "✅ Удалён: $DISPLAY"
      pause
      ;;

    "🖥️  Управление сервером")
      server_menu
      ;;

    "❌ Выход")
      clear
      exit 0
      ;;
  esac
done
EOF

chmod +x /usr/local/bin/amnezia