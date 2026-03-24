#!/usr/bin/env python3

import asyncio
import io
import logging
import os
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

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

bot = Bot(token=BOT_TOKEN)
dp  = Dispatcher(storage=MemoryStorage())

# ───────────────── FSM ─────────────────
class AddClient(StatesGroup):
    waiting_name = State()

# ───────────────── RUN ─────────────────
def run(cmd):
    result = subprocess.run(
        cmd if isinstance(cmd, list) else ["bash", "-c", cmd],
        capture_output=True,
        text=True,
        timeout=120
    )
    return result.stdout.strip(), result.stderr.strip()

# ───────────────── AWG PARSER ─────────────────
def parse_awg():
    out, _ = run(["awg", "show"])
    peers = {}
    current = None

    for line in out.splitlines():
        line = line.strip()

        if line.startswith("peer:"):
            current = line.split("peer:")[1].strip()
            peers[current] = {}
        elif current:
            if line.startswith("endpoint:"):
                peers[current]["endpoint"] = line.split("endpoint:")[1].strip()
            elif line.startswith("allowed ips:"):
                peers[current]["ip"] = line.split("allowed ips:")[1].split("/")[0]
            elif line.startswith("latest handshake:"):
                peers[current]["handshake"] = line.split("latest handshake:")[1].strip()
            elif line.startswith("transfer:"):
                peers[current]["transfer"] = line.split("transfer:")[1].strip()

    return peers

# ───────────────── CLIENTS ─────────────────
def get_clients():
    clients = []
    peers = parse_awg()

    for file in os.listdir(VPN_DIR):
        if not file.endswith("_displayname.txt"):
            continue

        name = file.replace("_displayname.txt", "")
        if name == "server":
            continue

        try:
            with open(f"{VPN_DIR}/{file}") as f:
                display = f.read().strip()
        except:
            display = name

        try:
            with open(f"{VPN_DIR}/{name}_public.key") as f:
                pub = f.read().strip()
        except:
            pub = None

        peer = peers.get(pub, {}) if pub else {}

        clients.append({
            "safe_name": name,
            "display": display,
            "ip": peer.get("ip", "—"),
        })

    return clients

def get_client_info(safe_name: str):
    try:
        with open(f"{VPN_DIR}/{safe_name}_public.key") as f:
            pub = f.read().strip()
    except:
        return None

    try:
        with open(f"{VPN_DIR}/{safe_name}_displayname.txt") as f:
            display = f.read().strip()
    except:
        display = safe_name

    peer = parse_awg().get(pub, {})

    return {
        "display": display,
        "pub_key": pub,
        "ip": peer.get("ip", "—"),
        "endpoint": peer.get("endpoint", "—"),
        "handshake": peer.get("handshake", "—"),
        "transfer": peer.get("transfer", "—"),
    }

# ───────────────── CLIENT OPS ─────────────────
def add_client(display_name: str):
    safe = re.sub(r"[^a-zA-Z0-9_-]", "_", display_name)
    out, err = run(["awg-add-client", safe, display_name])
    if "error" in (out + err).lower():
        return False, out or err
    return True, safe

def delete_client(safe_name: str):
    try:
        with open(f"{VPN_DIR}/{safe_name}_public.key") as f:
            pub = f.read().strip()
    except:
        return False, "no key"

    run(["awg", "set", "awg0", "peer", pub, "remove"])
    run(["awg-quick", "save", f"{VPN_DIR}/awg0.conf"])

    for f in os.listdir(VPN_DIR):
        if f.startswith(safe_name):
            os.remove(os.path.join(VPN_DIR, f))

    return True, ""

# ───────────────── SERVER ─────────────────
def get_server_status():
    awg, _ = run(["awg", "show"])
    fwd, _ = run(["sysctl", "-n", "net.ipv4.ip_forward"])
    uptime, _ = run(["uptime", "-p"])

    count = len([f for f in os.listdir(VPN_DIR) if f.endswith("_displayname.txt") and "server" not in f])

    return f"""
🖥️ <b>Статус</b>

Forwarding: {fwd}
Uptime: {uptime}
Clients: {count}

<pre>{awg}</pre>
"""

# ───────────────── UI ─────────────────
def main_menu_kb():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="➕ Добавить", callback_data="add")],
        [InlineKeyboardButton(text="📋 Клиенты", callback_data="list")],
    ])

def back_menu():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="⬅️ Назад", callback_data="menu")]
    ])

# ───────────────── HANDLERS ─────────────────
def is_admin(uid):
    return uid == ADMIN_ID

@dp.message(Command("start"))
async def start(msg: Message):
    if not is_admin(msg.from_user.id):
        return
    await msg.answer("Меню", reply_markup=main_menu_kb())

@dp.callback_query(F.data == "menu")
async def menu(cb: CallbackQuery):
    await cb.message.edit_text("Меню", reply_markup=main_menu_kb())

@dp.callback_query(F.data == "list")
async def list_clients(cb: CallbackQuery):
    clients = get_clients()

    text = "\n".join([f"{c['display']} ({c['ip']})" for c in clients]) or "нет клиентов"

    await cb.message.edit_text(text, reply_markup=back_menu())

@dp.callback_query(F.data == "add")
async def add(cb: CallbackQuery, state: FSMContext):
    await state.set_state(AddClient.waiting_name)
    await cb.message.edit_text("Имя клиента?")

@dp.message(AddClient.waiting_name)
async def add_process(msg: Message, state: FSMContext):
    ok, res = add_client(msg.text)

    if ok:
        await msg.answer(f"✅ создан {res}", reply_markup=main_menu_kb())
    else:
        await msg.answer(f"❌ {res}", reply_markup=main_menu_kb())

    await state.clear()

# ───────────────── MAIN ─────────────────
async def main():
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())