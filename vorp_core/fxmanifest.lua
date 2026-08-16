fx_version 'cerulean'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
game 'rdr3'

lua54 'yes'

description 'VORP Core compatibility bridge for hexa_core (ไม่ใช่ vorp_core ตัวจริง)'
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

dependencies {
    'hexa_core',
}
