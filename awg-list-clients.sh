cat > /usr/local/bin/awg-list-clients << 'EOF'
#!/bin/bash
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

DIR="/etc/amnezia/amneziawg"

# Проверка наличия клиентов
if ! ls $DIR/client_*_public.key > /dev/null 2>&1; then
  echo "Нет клиентов"
  exit 0
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                      КЛИЕНТЫ AWG                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

COUNT=0
for PUBKEY_FILE in $DIR/client_*_public.key; do
  [ -f "$PUBKEY_FILE" ] || continue

  # Извлекаем BASE_NAME (например client_iphone)
  BASE=$(basename "$PUBKEY_FILE" _public.key)

  # Название устройства
  if [ -f "$DIR/${BASE}_displayname.txt" ]; then
    DISPLAY_NAME=$(cat "$DIR/${BASE}_displayname.txt")
  else
    DISPLAY_NAME="$BASE"
  fi

  # Публичный ключ
  PUBKEY=$(cat "$PUBKEY_FILE")

  # IP из конфига клиента
  IP=$(grep "^Address" "$DIR/${BASE}.conf" 2>/dev/null | awk '{print $3}' | cut -d'/' -f1)

  COUNT=$((COUNT + 1))
  echo "  📱 $DISPLAY_NAME"
  echo "     IP:  ${IP:-не найден}"
  echo "     Key: $PUBKEY"
  echo ""
done

echo "  Всего клиентов: $COUNT"
echo ""
EOF

chmod +x /usr/local/bin/awg-list-clients