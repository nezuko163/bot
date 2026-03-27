cat > /usr/local/bin/awg-remove-client << 'EOF'
#!/bin/bash
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

DIR="/etc/amnezia/amneziawg"

# --- СПИСОК КЛИЕНТОВ ---
CLIENTS=$(ls $DIR/client_*_displayname.txt 2>/dev/null)

if [ -z "$CLIENTS" ]; then
  echo "❌ Нет клиентов"
  exit 1
fi

# --- ВЫБОР КЛИЕНТА ---
CLIENT=$(for f in $DIR/client_*_displayname.txt; do
  NAME=$(cat "$f")
  SAFE=$(basename "$f" | sed 's/_displayname\.txt//')
  PUB=$(cat "$DIR/${SAFE}_public.key" 2>/dev/null)
  IP=$(grep "AllowedIPs" "$DIR/${SAFE}.conf" 2>/dev/null | head -1 | awk '{print $3}' | cut -d'/' -f1)
  echo "$NAME | ${IP:-none} | $SAFE"
done | fzf --height=15 --border --no-info \
           --delimiter="|" \
           --with-nth=1,2 \
           --pointer="➤" \
           --header="Выбери клиента для удаления")

[ -z "$CLIENT" ] && exit 0

SAFE=$(echo "$CLIENT" | awk -F'|' '{print $3}' | xargs)
DISPLAY=$(echo "$CLIENT" | awk -F'|' '{print $1}' | xargs)
PUB=$(cat "$DIR/${SAFE}_public.key" 2>/dev/null)

if [ -z "$PUB" ]; then
  echo "❌ Не найден публичный ключ для $DISPLAY"
  exit 1
fi

# --- ПОДТВЕРЖДЕНИЕ ---
read -p "Удалить '$DISPLAY'? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Отменено"
  exit 0
fi

# --- УДАЛЕНИЕ ИЗ ЖИВОГО ИНТЕРФЕЙСА ---
awg set awg0 peer $PUB remove
echo "✅ Peer удалён из интерфейса"

# --- УДАЛЕНИЕ ИЗ awg0.conf ---
# Удаляем блок [Peer] с этим PublicKey (включая комментарий выше)
python3 - "$DIR/awg0.conf" "$PUB" << 'PYEOF'
import sys

conf_path = sys.argv[1]
pub_key = sys.argv[2]

with open(conf_path, 'r') as f:
    content = f.read()

blocks = content.split('\n\n')
filtered = []

for block in blocks:
    if '[Peer]' in block and pub_key in block:
        continue
    filtered.append(block)

with open(conf_path, 'w') as f:
    f.write('\n\n'.join(filtered))
PYEOF

echo "✅ Peer удалён из awg0.conf"

# --- УДАЛЕНИЕ ФАЙ