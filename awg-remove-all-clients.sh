cat > /usr/local/bin/awg-remove-all-clients << 'EOF'
#!/bin/bash
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

DIR="/etc/amnezia/amneziawg"

echo "⚠️  Будут удалены ВСЕ клиенты. Продолжить? (yes/no)"
read -r CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Отменено."
  exit 0
fi

# --- УДАЛЕНИЕ ПИРОВ ИЗ ЖИВОГО ИНТЕРФЕЙСА ---
for PUBKEY_FILE in $DIR/client_*_public.key; do
  [ -f "$PUBKEY_FILE" ] || continue
  PUBKEY=$(cat "$PUBKEY_FILE")
  awg set awg0 peer "$PUBKEY" remove
  echo "🔌 Удалён из интерфейса: $PUBKEY"
done

# --- УДАЛЕНИЕ ФАЙЛОВ КЛИЕНТОВ ---
rm -f $DIR/client_*_private.key
rm -f $DIR/client_*_public.key
rm -f $DIR/client_*.conf
rm -f $DIR/client_*_displayname.txt

# --- УДАЛЕНИЕ [Peer] БЛОКОВ ИЗ awg0.conf ---
awk '
  /^\[Peer\]/ { skip=1; next }
  /^\[Interface\]/ { skip=0 }
  !skip { print }
' $DIR/awg0.conf > $DIR/awg0.conf.tmp && mv $DIR/awg0.conf.tmp $DIR/awg0.conf

echo ""
echo "✅ Все клиенты удалены"
EOF

chmod +x /usr/local/bin/awg-remove-all-clients