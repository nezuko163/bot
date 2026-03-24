#!/usr/bin/env python3
"""
AmneziaVPN Telegram Bot
Управление клиентами AmneziaWG — локальный запуск (subprocess)
"""

import asyncio
import io
import logging
import re
import subprocess
import urllib.parse
import base64
from typing import Optional

from aiogram import Bot, Dispatcher, F
from aiogram.filters import Command
from aiogram.types import (
    Message, CallbackQuery,
    InlineKeyboardMarkup, InlineKeyboardButton
)
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage

from config import BOT_TOKEN, ADMIN_ID, VPN_DIR

# ─── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger(__name__)

# ─── Bot & Dispatcher ─────────────────────────────────────────────────────────
bot = Bot(token=BOT_TOKEN)
dp  = Dispatcher(storage=MemoryStorage())

# ─── FSM States ───────────────────────────────────────────────────────────────
class AddClient(StatesGroup):
    waiting_name = State()

# ─── Shell helper ─────────────────────────────────────────────────────────────
def run(cmd: list[str]) -> tuple[str, str]:
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=120
    )
    return result.stdout.strip(), result.stderr.strip()

# ─── Admin guard ──────────────────────────────────────────────────────────────
def is_admin(user_id: int) -> bool:
    return user_id == ADMIN_ID

# ─── Keyboards ────────────────────────────────────────────────────────────────
def main_menu_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="➕ Добавить клиента",   callback_data="add_client")],
        [InlineKeyboardButton(text="📋 Список клиентов",    callback_data="list_clients")],
        [InlineKeyboardButton(text="🗑️ Удалить клиента",    callback_data="delete_client")],
        [InlineKeyboardButton(text="🖥️ Управление сервером", callback_data="server_status")],
    ])

def client_actions_kb(safe_name: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📱 Получить ссылку", callback_data=f"link|{safe_name}")],
        [InlineKeyboardButton(text="📄 Показать конфиг", callback_data=f"conf|{safe_name}")],
        [InlineKeyboardButton(text="👁️ Детали",          callback_data=f"info|{safe_name}")],
        [InlineKeyboardButton(text="🗑️ Удалить",         callback_data=f"del|{safe_name}")],
        [InlineKeyboardButton(text="⬅️ Назад",            callback_data="list_clients")],
    ])

def server_menu_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="▶️ Запустить",    callback_data="srv_start")],
        [InlineKeyboardButton(text="🔄 Перезапустить", callback_data="srv_restart")],
        [InlineKeyboardButton(text="⏹️ Остановить",   callback_data="srv_stop")],
        [InlineKeyboardButton(text="🔧 Починить",     callback_data="srv_fix")],
        [InlineKeyboardButton(text="📊 Обновить статус", callback_data="server_status")],
        [InlineKeyboardButton(text="⬅️ Главное меню", callback_data="main_menu")],
    ])

def back_to_list_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="⬅️ К списку клиентов", callback_data="list_clients")],
        [InlineKeyboardButton(text="🏠 Главное меню",       callback_data="main_menu")],
    ])

def back_to_menu_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="⬅️ Главное меню", callback_data="main_menu")]
    ])

def confirm_delete_kb(safe_name: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="✅ Да, удалить", callback_data=f"confirm_del|{safe_name}"),
        InlineKeyboardButton(text="❌ Отмена",      callback_data=f"client|{safe_name}"),
    ]])

# ─── VPN helpers ──────────────────────────────────────────────────────────────
def get_clients() -> list[dict]:
    """Возвращает список клиентов [{display, safe_name, ip}]."""
    cmd = (
        f"for f in {VPN_DIR}/*_displayname.txt; do "
        f"  name=$(basename \"$f\" _displayname.txt); "
        f"  [ \"$name\" = 'server' ] && continue; "
        f"  display=$(cat \"$f\"); "
        f"  pub=$(cat \"{VPN_DIR}/${{name}}_public.key\" 2>/dev/null); "
        f"  ip=$(awg show awg0 allowed-ips 2>/dev/null | grep \"$pub\" | awk '{{print $2}}' | cut -d'/' -f1); "
        f"  echo \"$name|$display|$ip\"; "
        f"done"
    )
    out, _ = run(cmd)
    clients = []
    if out:
        for line in out.splitlines():
            parts = line.split("|", 2)
            if len(parts) == 3:
                clients.append({
                    "safe_name": parts[0],
                    "display":   parts[1],
                    "ip":        parts[2],
                })
    return clients


def add_client(display_name: str) -> tuple[bool, str]:
    """Создаёт нового клиента через awg-add-client."""
    safe = re.sub(r"[^a-zA-Z0-9_-]", "_", display_name)
    out, err = run(["awg-add-client", safe, display_name])
    combined = (out + err).lower()
    if "error" in combined or "fail" in combined:
        return False, out or err
    return True, safe


def delete_client(safe_name: str) -> tuple[bool, str]:
    """Удаляет клиента из конфига и файловой системы."""
    pub, _ = run(f"cat {VPN_DIR}/{safe_name}_public.key 2>/dev/null")
    if not pub:
        return False, "Публичный ключ не найден"
    run(f"awg set awg0 peer {pub} remove")
    run(f"awg-quick save {VPN_DIR}/awg0.conf")
    _, err = run(f"rm -f {VPN_DIR}/{safe_name}_*")
    if err and "error" in err.lower():
        return False, err
    return True, ""


def get_client_config(safe_name: str) -> Optional[str]:
    out, _ = run(f"cat {VPN_DIR}/{safe_name}.conf 2>/dev/null")
    return out if out else None


def get_client_link(safe_name: str, display_name: str) -> Optional[str]:
    conf, _ = run(f"cat {VPN_DIR}/{safe_name}.conf 2>/dev/null")
    if not conf:
        return None
    conf_b64     = base64.b64encode(conf.encode()).decode()
    encoded_name = urllib.parse.quote(display_name)
    return f"vpn://{conf_b64}?name={encoded_name}"


def get_client_info(safe_name: str) -> Optional[dict]:
    pub_key, _ = run(f"cat {VPN_DIR}/{safe_name}_public.key 2>/dev/null")
    display, _ = run(f"cat {VPN_DIR}/{safe_name}_displayname.txt 2>/dev/null")
    if not pub_key:
        return None
    ip,        _ = run(f"awg show awg0 allowed-ips 2>/dev/null | grep '{pub_key}' | awk '{{print $2}}'")
    endpoint,  _ = run(f"awg show awg0 endpoints 2>/dev/null | grep '{pub_key}' | awk '{{print $2}}'")
    handshake, _ = run(f"awg show awg0 latest-handshakes 2>/dev/null | grep '{pub_key}' | awk '{{print $2}}'")
    transfer,  _ = run(f"awg show awg0 transfer 2>/dev/null | grep '{pub_key}' | awk '{{print $2\" / \"$3}}'")
    return {
        "display":   display or safe_name,
        "pub_key":   pub_key,
        "ip":        ip        or "—",
        "endpoint":  endpoint  or "—",
        "handshake": handshake or "—",
        "transfer":  transfer  or "—",
    }


def get_server_status() -> str:
    """Полный статус: awg, forwarding, NAT, клиенты."""
    port, _       = run("awg show awg0 2>/dev/null | grep 'listening port' | awk '{print $3}'")
    fwd, _        = run("sysctl -n net.ipv4.ip_forward")
    awg_info, _   = run("awg show 2>/dev/null || echo 'Сервер не запущен'")
    nat, _        = run("iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null")
    uptime_str, _ = run("uptime -p 2>/dev/null")
    count, _      = run(f"ls {VPN_DIR}/*_displayname.txt 2>/dev/null | grep -v server | wc -l")

    server_icon = "🟢" if port else "🔴"
    server_str  = f"Запущен (порт {port})" if port else "Остановлен"
    fwd_icon    = "🟢" if fwd.strip() == "1" else "🔴"
    fwd_str     = "Включён" if fwd.strip() == "1" else "Выключен"

    return (
        f"🖥️ <b>Статус сервера</b>\n\n"
        f"{server_icon} Сервер:        <b>{server_str}</b>\n"
        f"{fwd_icon} IP Forwarding: <b>{fwd_str}</b>\n"
        f"⏱ Uptime:       <code>{uptime_str}</code>\n"
        f"👥 Клиентов:    <b>{count}</b>\n\n"
        f"<b>awg show:</b>\n<pre>{awg_info}</pre>\n"
        f"<b>NAT (POSTROUTING):</b>\n<pre>{nat or '—'}</pre>"
    )


def server_start() -> tuple[bool, str]:
    run("sysctl -w net.ipv4.ip_forward=1")
    out, err = run(f"awg-quick up {VPN_DIR}/awg0.conf 2>&1")
    if "error" in (out + err).lower() and "already exists" not in (out + err).lower():
        return False, out or err
    return True, out


def server_stop() -> tuple[bool, str]:
    out, err = run(f"awg-quick down {VPN_DIR}/awg0.conf 2>&1")
    if "error" in (out + err).lower() and "does not exist" not in (out + err).lower():
        return False, out or err
    return True, out


def server_restart() -> tuple[bool, str]:
    run(f"awg-quick down {VPN_DIR}/awg0.conf 2>/dev/null")
    import time; time.sleep(1)
    run("sysctl -w net.ipv4.ip_forward=1")
    out, err = run(f"awg-quick up {VPN_DIR}/awg0.conf 2>&1")
    if "error" in (out + err).lower():
        return False, out or err
    return True, out


def server_fix() -> str:
    import time
    lines = []

    run("sysctl -w net.ipv4.ip_forward=1")
    run("echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-vpn.conf")
    run("sysctl -p /etc/sysctl.d/99-vpn.conf")
    lines.append("✅ IP Forwarding включён")

    run("iptables -A INPUT -p udp --dport 51820 -j ACCEPT 2>/dev/null")
    run("iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null")
    lines.append("✅ Порт 51820 открыт")

    _, err = run("netfilter-persistent save 2>/dev/null")
    lines.append("✅ Правила iptables сохранены" if not err else f"⚠️ netfilter-persistent: {err}")

    run(f"awg-quick down {VPN_DIR}/awg0.conf 2>/dev/null")
    time.sleep(1)
    out, err2 = run(f"awg-quick up {VPN_DIR}/awg0.conf 2>&1")
    if err2 and "error" in err2.lower():
        lines.append(f"❌ Ошибка запуска:\n<code>{err2}</code>")
    else:
        lines.append("✅ Сервер перезапущен")

    return "\n".join(lines)

# ─── Handlers ─────────────────────────────────────────────────────────────────

@dp.message(Command("start"))
async def cmd_start(msg: Message, state: FSMContext):
    if not is_admin(msg.from_user.id):
        return await msg.answer("⛔ Доступ запрещён.")
    await state.clear()
    await msg.answer(
        "🛡️ <b>AmneziaVPN Manager</b>\n\nВыбери действие:",
        reply_markup=main_menu_kb(),
        parse_mode="HTML"
    )


@dp.message(Command("menu"))
async def cmd_menu(msg: Message, state: FSMContext):
    if not is_admin(msg.from_user.id):
        return
    await state.clear()
    await msg.answer("🛡️ <b>Главное меню</b>", reply_markup=main_menu_kb(), parse_mode="HTML")


@dp.callback_query(F.data == "main_menu")
async def cb_main_menu(cb: CallbackQuery, state: FSMContext):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔ Нет доступа", show_alert=True)
    await state.clear()
    await cb.message.edit_text(
        "🛡️ <b>Главное меню</b>",
        reply_markup=main_menu_kb(),
        parse_mode="HTML"
    )
    await cb.answer()


# ─── Add client ───────────────────────────────────────────────────────────────

@dp.callback_query(F.data == "add_client")
async def cb_add_client(cb: CallbackQuery, state: FSMContext):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔", show_alert=True)
    await state.set_state(AddClient.waiting_name)
    await cb.message.edit_text(
        "➕ <b>Новый клиент</b>\n\nВведи имя клиента:",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="❌ Отмена", callback_data="main_menu")]
        ]),
        parse_mode="HTML"
    )
    await cb.answer()


@dp.message(AddClient.waiting_name)
async def process_add_client(msg: Message, state: FSMContext):
    if not is_admin(msg.from_user.id):
        return
    name = msg.text.strip()
    if not name:
        return await msg.answer("Имя не может быть пустым. Попробуй ещё раз:")

    wait = await msg.answer(f"⏳ Создаю клиента <b>{name}</b>...", parse_mode="HTML")
    try:
        ok, safe_or_err = add_client(name)
    except Exception as e:
        await wait.edit_text(
            f"❌ Ошибка: <code>{e}</code>",
            parse_mode="HTML", reply_markup=back_to_menu_kb()
        )
        await state.clear()
        return

    await state.clear()
    if ok:
        await wait.edit_text(
            f"✅ Клиент <b>{name}</b> создан!",
            parse_mode="HTML",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text="📱 Получить ссылку", callback_data=f"link|{safe_or_err}")],
                [InlineKeyboardButton(text="📄 Конфиг",          callback_data=f"conf|{safe_or_err}")],
                [InlineKeyboardButton(text="⬅️ Меню",            callback_data="main_menu")],
            ])
        )
    else:
        await wait.edit_text(
            f"❌ Ошибка:\n<code>{safe_or_err}</code>",
            parse_mode="HTML", reply_markup=back_to_menu_kb()
        )


# ─── List clients ─────────────────────────────────────────────────────────────

@dp.callback_query(F.data == "list_clients")
async def cb_list_clients(cb: CallbackQuery, state: FSMContext):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔", show_alert=True)
    await state.clear()
    await cb.message.edit_text("⏳ Загружаю список клиентов...", parse_mode="HTML")

    try:
        clients = get_clients()
    except Exception as e:
        return await cb.message.edit_text(
            f"❌ Ошибка: <code>{e}</code>", parse_mode="HTML",
            reply_markup=back_to_menu_kb()
        )

    if not clients:
        return await cb.message.edit_text("📋 Клиентов нет.", reply_markup=back_to_menu_kb())

    buttons = [
        [InlineKeyboardButton(
            text=f"👤 {c['display']}  [{c['ip'] or '?'}]",
            callback_data=f"client|{c['safe_name']}"
        )]
        for c in clients
    ]
    buttons.append([InlineKeyboardButton(text="⬅️ Главное меню", callback_data="main_menu")])

    await cb.message.edit_text(
        f"📋 <b>Клиенты ({len(clients)})</b>:",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=buttons),
        parse_mode="HTML"
    )
    await cb.answer()


# ─── Client actions menu ──────────────────────────────────────────────────────

@dp.callback_query(F.data.startswith("client|"))
async def cb_client(cb: CallbackQuery):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔", show_alert=True)
    safe_name = cb.data.split("|", 1)[1]
    display, _ = run(f"cat {VPN_DIR}/{safe_name}_displayname.txt 2>/dev/null")
    display = display or safe_name

    await cb.message.edit_text(
        f"👤 <b>{display}</b>\n\nВыбери действие:",
        reply_markup=client_actions_kb(safe_name),
        parse_mode="HTML"
    )
    await cb.answer()


# ─── Client info ──────────────────────────────────────────────────────────────

@dp.callback_query(F.data.startswith("info|"))
async def cb_info(cb: CallbackQuery):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔", show_alert=True)
    safe_name = cb.data.split("|", 1)[1]
    await cb.message.edit_text("⏳ Получаю данные...", parse_mode="HTML")

    try:
        info = get_client_info(safe_name)
    except Exception as e:
        return await cb.message.edit_text(
            f"❌ Ошибка: <code>{e}</code>", parse_mode="HTML",
            reply_markup=back_to_list_kb()
        )

    if not info:
        return await cb.message.edit_text("❌ Клиент не найден.", reply_markup=back_to_list_kb())

    text = (
        f"👤 <b>{info['display']}</b>\n\n"
        f"🌐 IP:         <code>{info['ip']}</code>\n"
        f"🔌 Endpoint:  <code>{info['endpoint']}</code>\n"
        f"🤝 Handshake: <code>{info['handshake']}</code>\n"
        f"📊 Трафик:    <code>{info['transfer']}</code>\n\n"
        f"🔑 Public key:\n<code>{info['pub_key']}</code>"
    )
    await cb.message.edit_text(text, parse_mode="HTML", reply_markup=client_actions_kb(safe_name))
    await cb.answer()


# ─── Client config ────────────────────────────────────────────────────────────

@dp.callback_query(F.data.startswith("conf|"))
async def cb_conf(cb: CallbackQuery):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔", show_alert=True)
    safe_name = cb.data.split("|", 1)[1]
    await cb.answer("⏳ Загружаю конфиг...")

    try:
        conf = get_client_config(safe_name)
    except Exception as e:
        return await cb.message.answer(f"❌ Ошибка: <code>{e}</code>", parse_mode="HTML")

    if not conf:
        return await cb.message.answer("❌ Конфиг не найден.")

    conf_file      = io.BytesIO(conf.encode())
    conf_file.name = f"{safe_name}.conf"
    await cb.message.answer_document(
        document=conf_file,
        caption=f"📄 Конфиг: <code>{safe_name}</code>",
        parse_mode="HTML"
    )


# ─── Client link ─────────────────────────────────────────────────────────────

@dp.callback_query(F.data.startswith("link|"))
async def cb_link(cb: CallbackQuery):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔", show_alert=True)
    safe_name = cb.data.split("|", 1)[1]
    await cb.message.edit_text("⏳ Генерирую ссылку...", parse_mode="HTML")

    try:
        display, _ = run(f"cat {VPN_DIR}/{safe_name}_displayname.txt 2>/dev/null")
        link = get_client_link(safe_name, display or safe_name)
    except Exception as e:
        return await cb.message.edit_text(
            f"❌ Ошибка: <code>{e}</code>", parse_mode="HTML",
            reply_markup=back_to_list_kb()
        )

    if not link:
        return await cb.message.edit_text("❌ Конфиг не найден.", reply_markup=back_to_list_kb())

    await cb.message.edit_text(
        "📱 <b>Ссылка для подключения</b>\n\nОткрой в приложении AmneziaVPN:",
        parse_mode="HTML",
        reply_markup=client_actions_kb(safe_name)
    )
    await cb.message.answer(f"<code>{link}</code>", parse_mode="HTML")
    await cb.answer()


# ─── Delete client ────────────────────────────────────────────────────────────

@dp.callback_query(F.data == "delete_client")
async def cb_delete_client(cb: CallbackQuery, state: FSMContext):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔", show_alert=True)
    await cb.message.edit_text("⏳ Загружаю клиентов...", parse_mode="HTML")

    try:
        clients = get_clients()
    except Exception as e:
        return await cb.message.edit_text(
            f"❌ Ошибка: <code>{e}</code>", parse_mode="HTML",
            reply_markup=back_to_menu_kb()
        )

    if not clients:
        return await cb.message.edit_text("Клиентов нет.", reply_markup=back_to_menu_kb())

    buttons = [
        [InlineKeyboardButton(
            text=f"🗑️ {c['display']}  [{c['ip'] or '?'}]",
            callback_data=f"del|{c['safe_name']}"
        )]
        for c in clients
    ]
    buttons.append([InlineKeyboardButton(text="⬅️ Главное меню", callback_data="main_menu")])

    await cb.message.edit_text(
        "🗑️ <b>Выбери клиента для удаления:</b>",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=buttons),
        parse_mode="HTML"
    )
    await cb.answer()


@dp.callback_query(F.data.startswith("del|"))
async def cb_del(cb: CallbackQuery):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔", show_alert=True)
    safe_name = cb.data.split("|", 1)[1]
    display, _ = run(f"cat {VPN_DIR}/{safe_name}_displayname.txt 2>/dev/null")
    display = display or safe_name

    await cb.message.edit_text(
        f"⚠️ Удалить клиента <b>{display}</b>?\n\nЭто действие необратимо.",
        reply_markup=confirm_delete_kb(safe_name),
        parse_mode="HTML"
    )
    await cb.answer()


@dp.callback_query(F.data.startswith("confirm_del|"))
async def cb_confirm_del(cb: CallbackQuery):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔", show_alert=True)
    safe_name = cb.data.split("|", 1)[1]
    display, _ = run(f"cat {VPN_DIR}/{safe_name}_displayname.txt 2>/dev/null")
    display = display or safe_name

    await cb.message.edit_text(f"⏳ Удаляю <b>{display}</b>...", parse_mode="HTML")

    try:
        ok, err = delete_client(safe_name)
    except Exception as e:
        return await cb.message.edit_text(
            f"❌ Ошибка: <code>{e}</code>", parse_mode="HTML",
            reply_markup=back_to_menu_kb()
        )

    if ok:
        await cb.message.edit_text(
            f"✅ Клиент <b>{display}</b> удалён.",
            parse_mode="HTML", reply_markup=back_to_menu_kb()
        )
    else:
        await cb.message.edit_text(
            f"❌ Ошибка:\n<code>{err}</code>",
            parse_mode="HTML", reply_markup=back_to_menu_kb()
        )
    await cb.answer()


# ─── Server status ────────────────────────────────────────────────────────────

@dp.callback_query(F.data == "server_status")
async def cb_server_status(cb: CallbackQuery):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔", show_alert=True)
    await cb.message.edit_text("⏳ Получаю статус сервера...", parse_mode="HTML")

    try:
        status = get_server_status()
    except Exception as e:
        return await cb.message.edit_text(
            f"❌ Ошибка: <code>{e}</code>", parse_mode="HTML",
            reply_markup=back_to_menu_kb()
        )

    await cb.message.edit_text(status, parse_mode="HTML", reply_markup=server_menu_kb())
    await cb.answer()


@dp.callback_query(F.data == "srv_start")
async def cb_srv_start(cb: CallbackQuery):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔", show_alert=True)
    await cb.message.edit_text("⏳ Запускаю сервер...", parse_mode="HTML")
    try:
        ok, out = server_start()
    except Exception as e:
        return await cb.message.edit_text(
            f"❌ Ошибка: <code>{e}</code>", parse_mode="HTML",
            reply_markup=server_menu_kb()
        )
    icon = "✅" if ok else "❌"
    text = f"{icon} {'Сервер запущен' if ok else 'Ошибка запуска'}"
    if out:
        text += f"\n\n<pre>{out}</pre>"
    await cb.message.edit_text(text, parse_mode="HTML", reply_markup=server_menu_kb())
    await cb.answer()


@dp.callback_query(F.data == "srv_stop")
async def cb_srv_stop(cb: CallbackQuery):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔", show_alert=True)
    await cb.message.edit_text("⏳ Останавливаю сервер...", parse_mode="HTML")
    try:
        ok, out = server_stop()
    except Exception as e:
        return await cb.message.edit_text(
            f"❌ Ошибка: <code>{e}</code>", parse_mode="HTML",
            reply_markup=server_menu_kb()
        )
    icon = "✅" if ok else "❌"
    text = f"{icon} {'Сервер остановлен' if ok else 'Ошибка остановки'}"
    if out:
        text += f"\n\n<pre>{out}</pre>"
    await cb.message.edit_text(text, parse_mode="HTML", reply_markup=server_menu_kb())
    await cb.answer()


@dp.callback_query(F.data == "srv_restart")
async def cb_srv_restart(cb: CallbackQuery):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔", show_alert=True)
    await cb.message.edit_text("⏳ Перезапускаю сервер...", parse_mode="HTML")
    try:
        ok, out = server_restart()
    except Exception as e:
        return await cb.message.edit_text(
            f"❌ Ошибка: <code>{e}</code>", parse_mode="HTML",
            reply_markup=server_menu_kb()
        )
    icon = "✅" if ok else "❌"
    text = f"{icon} {'Сервер перезапущен' if ok else 'Ошибка перезапуска'}"
    if out:
        text += f"\n\n<pre>{out}</pre>"
    await cb.message.edit_text(text, parse_mode="HTML", reply_markup=server_menu_kb())
    await cb.answer()


@dp.callback_query(F.data == "srv_fix")
async def cb_srv_fix(cb: CallbackQuery):
    if not is_admin(cb.from_user.id):
        return await cb.answer("⛔", show_alert=True)
    await cb.message.edit_text("⏳ Применяю исправления...", parse_mode="HTML")
    try:
        result = server_fix()
    except Exception as e:
        return await cb.message.edit_text(
            f"❌ Ошибка: <code>{e}</code>", parse_mode="HTML",
            reply_markup=server_menu_kb()
        )
    await cb.message.edit_text(
        f"🔧 <b>Результат починки:</b>\n\n{result}",
        parse_mode="HTML", reply_markup=server_menu_kb()
    )
    await cb.answer()


# ─── Entry point ──────────────────────────────────────────────────────────────

async def main():
    logger.info("Запуск бота...")
    await dp.start_polling(bot, skip_updates=True)


if __name__ == "__main__":
    asyncio.run(main())
