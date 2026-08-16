fx_version 'cerulean'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
game 'rdr3'

lua54 'yes'

description 'rsg-core compatibility bridge for hexa_core (ไม่ใช่ rsg-core ตัวจริง)'
version '1.0.0'

shared_scripts {
    -- ลำดับสำคัญ: config -> bridge -> ที่เหลือ
    'config.lua',
    'shared/bridge.lua',
}

client_scripts {
    'client/main.lua',
}

server_scripts {
    'server/main.lua',
}

-- สคริปต์ RSG จำนวนมากประกาศ '@rsg-core/shared/locale.lua' ใน fxmanifest ของตัวเอง
-- ไฟล์ข้ามresource แบบนั้นต้องอยู่ใน files{} ของเจ้าของไฟล์ ไม่งั้น client ของ
-- resource นั้นโหลดไม่ได้แบบเงียบ ๆ (ฝั่ง server ผ่านปกติ = ไล่บั๊กยากมาก)
files {
    'shared/locale.lua',
}

dependencies {
    'hexa_core',
}
