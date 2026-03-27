cat > /usr/local/bin/awg-add-client << 'EOF'
#!/bin/bash
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

DIR="/etc/amnezia/amneziawg"
SERVER_PUBLIC=$(cat $DIR/server_public.key)
SERVER_IP="194.154.30.212"
PORT="51820"

read -p "Введи название устройства: " DISPLAY_NAME
if [ -z "$DISPLAY_NAME" ]; then
  echo "❌ Название не может быть пустым"
  exit 1
fi

# --- ОЧИСТКА ИМЕНИ ---
SAFE_NAME=$(echo "$DISPLAY_NAME" | tr ' ' '_' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')

# Если после очистки пусто (было только кириллицей) — используем timestamp
if [ -z "$SAFE_NAME" ]; then
  SAFE_NAME="device_$(date +%s)"
fi

NAME="client_${SAFE_NAME}"

# --- ПРОВЕРКА НА ДУБЛИКАТ ---
if [ -f "$DIR/${NAME}_private.key" ]; then
  echo "❌ Клиент с таким именем уже существует"
  exit 1
fi

# --- ВЫДАЧА ПЕРВОГО СВОБОДНОГО IP ---
IP=""
for i in $(seq 2 254); do
  CANDIDATE="10.8.0.$i"
  if ! grep -r "AllowedIPs = ${CANDIDATE}/32" $DIR/ > /dev/null 2>&1; then
    IP="$CANDIDATE"
    break
  fi
done

if [ -z "$IP" ]; then
  echo "❌ Нет свободных IP адресов"
  exit 1
fi

# --- ГЕНЕРАЦИЯ КЛЮЧЕЙ ---
awg genkey | tee $DIR/${NAME}_private.key | awg pubkey > $DIR/${NAME}_public.key
chmod 600 $DIR/${NAME}_private.key

CLIENT_PUBLIC=$(cat $DIR/${NAME}_public.key)
CLIENT_PRIVATE=$(cat $DIR/${NAME}_private.key)

echo "$DISPLAY_NAME" > $DIR/${NAME}_displayname.txt

# --- КОНФИГ КЛИЕНТА ---
cat > $DIR/${NAME}.conf << CONF
[Interface]
PrivateKey = $CLIENT_PRIVATE
Address = ${IP}/32
DNS = 1.1.1.1
Jc = 5
Jmin = 20
Jmax = 100
S1 = 30
S2 = 40
H1 = 1234567
H2 = 2345678
H3 = 3456789
H4 = 4567890

[Peer]
PublicKey = $SERVER_PUBLIC
Endpoint = ${SERVER_IP}:${PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF

# --- ДОБАВЛЕНИЕ В СЕРВЕРНЫЙ КОНФИГ ---
cat >> $DIR/awg0.conf << PEER

[Peer]
# $DISPLAY_NAME
PublicKey = $CLIENT_PUBLIC
AdvancedSecurity = on
AllowedIPs = ${IP}/32
PEER

# --- ДОБАВЛЕНИЕ В ЖИВОЙ ИНТЕРФЕЙС ---
awg set awg0 peer $CLIENT_PUBLIC allowed-ips ${IP}/32

echo ""
echo "✅ Создан: $DISPLAY_NAME ($IP)"
echo ""

ENCODED_NAME=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$DISPLAY_NAME'''))")
CONF_B64=$(cat $DIR/${NAME}.conf | base64 | tr -d '\n')
echo "vpn://${CONF_B64}?name=${ENCODED_NAME}"
echo ""
EOF

chmod +x /usr/local/bin/awg-add-client