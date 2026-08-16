# hexa-bridge

ชุด **compatibility bridges** สำหรับ [hexa_core](https://github.com/hexa-development/hexa_core) — ทำให้สคริปต์ที่เขียนมาเพื่อ framework อื่นรันบนเซิร์ฟเวอร์ Hexa ได้ โดยไม่ต้องแก้โค้ดของสคริปต์นั้น

📖 เอกสารฉบับเต็ม: [hexa-development.github.io/hexa-docs](https://hexa-development.github.io/hexa-docs/)

## มีอะไรในชุดนี้

| Resource | คำอธิบาย |
| --- | --- |
| **rsg-core** | บริดจ์เลียน API ของ RSG-Core บน hexa_core (ไม่ใช่ rsg-core ตัวจริง) — สคริปต์ RSG เรียก `exports['rsg-core']:GetCoreObject()` ได้ตามปกติ |
| **vorp_core** | บริดจ์เลียน API ของ VORP Core บน hexa_core (ไม่ใช่ vorp_core ตัวจริง) — รองรับ `getCore()`, `AddWebhook` ฯลฯ |
| **hexa_mcp_bridge** | HTTP bridge ฝั่ง server เปิดสถานะ/การควบคุมแบบมีการ์ดให้ [MCP server](https://modelcontextprotocol.io/) (`hexa_mcp`) — ใช้ให้ AI/เครื่องมือ ops คุยกับเซิร์ฟเวอร์ได้อย่างปลอดภัย |

## การติดตั้ง

วางทั้งโฟลเดอร์ไว้ใน resources ของเซิร์ฟเวอร์ เช่น

```
resources/[scripts-hexa]/[bridge]/
├── rsg-core/
├── vorp_core/
└── hexa_mcp_bridge/
```

จากนั้นใน `server.cfg` — start เฉพาะตัวที่ต้องใช้ **หลัง** `hexa_core` เสมอ:

```ini
ensure hexa_core

# เลือกใช้ตามสคริปต์ที่มี
ensure rsg-core        # ถ้ามีสคริปต์ RSG
ensure vorp_core       # ถ้ามีสคริปต์ VORP
ensure hexa_mcp_bridge # ถ้าใช้ hexa_mcp MCP server
```

::: สำคัญ: ห้าม start บริดจ์คู่กับ core ตัวจริงของ framework นั้น (เช่น rsg-core ตัวจริง) เด็ดขาด — ชื่อ resource ชนกันโดยตั้งใจ

## การตั้งค่า hexa_mcp_bridge

resource นี้ **ฝั่ง server ล้วน ไม่มี client footprint** และปฏิเสธการทำงานถ้าไม่ตั้ง API key:

```ini
set hexa_mcp_api_key "your-32-char-or-longer-key"
```

- Key ต้องยาวอย่างน้อย 24 ตัวอักษร (แนะนำ 32+) และ **ห้าม hardcode ในไฟล์ config**
- จำกัดสิทธิ์เพิ่มได้ด้วย IP allowlist (`Config.AllowedIPs`) และ rate limit ตามระดับคำสั่ง (read / write / dangerous) ใน `hexa_mcp_bridge/config.lua`

## ข้อจำกัด

บริดจ์ครอบคลุม API ที่สคริปต์ทั่วไปใช้บ่อย — ถ้าเจอฟังก์ชันที่ยังไม่รองรับ เปิด issue มาได้เลย

## License

แจกฟรีสำหรับเซิร์ฟเวอร์ RedM — ใช้ ดัดแปลง แชร์ต่อได้ตามสะดวก
