#!/usr/bin/env python3
"""
Генератор vpn:// ссылки для AmneziaVPN (протокол AmneziaWG).

Формат: vpn:// + base64url( qCompress(JSON) )
  qCompress = 4 байта big-endian (размер оригинала) + zlib deflate level=8

Источник: amnezia-vpn/amnezia-client exportController.cpp L29-58
          https://github.com/amnezia-vpn/amnezia-client

Использование:
  python3 amnezia_encode.py <conf_path> <name> <Jc> <Jmin> <Jmax> <S1> <S2> <H1> <H2> <H3> <H4>
"""

import sys
import json
import zlib
import base64
import struct

def main():
    if len(sys.argv) < 12:
        print("Usage: amnezia_encode.py <conf> <name> <Jc> <Jmin> <Jmax> <S1> <S2> <H1> <H2> <H3> <H4>",
              file=sys.stderr)
        sys.exit(1)

    conf_path = sys.argv[1]
    name      = sys.argv[2]
    jc        = int(sys.argv[3])
    jmin      = int(sys.argv[4])
    jmax      = int(sys.argv[5])
    s1        = int(sys.argv[6])
    s2        = int(sys.argv[7])
    h1        = int(sys.argv[8])
    h2        = int(sys.argv[9])
    h3        = int(sys.argv[10])
    h4        = int(sys.argv[11])

    with open(conf_path, "r") as f:
        raw_conf = f.read()

    # last_config — JSON-строка (двойная сериализация, как требует importController.cpp)
    # Содержит конфиг и AWG-параметры обфускации
    last_config = json.dumps({
        "config":                       raw_conf,
        "junkPacketCount":              jc,      # Jc
        "junkPacketMinSize":            jmin,    # Jmin
        "junkPacketMaxSize":            jmax,    # Jmax
        "initPacketJunkSize":           s1,      # S1
        "responsePacketJunkSize":       s2,      # S2
        "initPacketMagicHeader":        h1,      # H1
        "responsePacketMagicHeader":    h2,      # H2
        "underloadPacketMagicHeader":   h3,      # H3
        "transportPacketMagicHeader":   h4,      # H4
    }, ensure_ascii=False, separators=(",", ":"))

    # Внешний JSON — структура контейнера AmneziaVPN
    payload = {
        "containers": [{
            "container": "amnezia-awg",
            "awg": {
                "last_config": last_config
            }
        }],
        "defaultContainer": "amnezia-awg",
        "description":      name,
        "dns1":             "1.1.1.1",
        "dns2":             "8.8.8.8"
    }

    # Сериализуем
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    # qCompress: 4-байтный big-endian заголовок с размером оригинала + zlib level=8
    # (level=8 соответствует Qt qCompress по умолчанию)
    compressed  = zlib.compress(data, level=8)
    qcompressed = struct.pack(">I", len(data)) + compressed

    # base64url без trailing =
    encoded = base64.urlsafe_b64encode(qcompressed).rstrip(b"=").decode("ascii")

    print("vpn://" + encoded)


if __name__ == "__main__":
    main()