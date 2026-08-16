--[[
    vorp_core (compat bridge) — การตั้งค่าการแปลง
    ---------------------------------------------------------------------
    แก้ไฟล์นี้เมื่อสคริปต์ VORP ที่เอามาลงใช้สกุลเงิน / กลุ่มสิทธิ์ ที่
    hexa_core ไม่มีตรงตัว
]]

BridgeConfig = {}

-- ==========================================
-- สกุลเงิน
-- ==========================================
-- VORP อ้างสกุลเงินด้วยตัวเลข: 0 = money (เงินสด), 1 = gold, 2 = rol (rollcoins)
-- hexa_core มีสามช่อง: cash / bank / gold
--   ตัวเลข = 'ช่องของ hexa'  -> แปลงแล้วใช้งานได้ปกติ
--   ตัวเลข = false           -> ไม่รองรับ (คืน false + เตือน console ครั้งเดียว)
BridgeConfig.Currency = {
    [0] = 'cash',
    [1] = 'gold',
    [2] = false,  -- rol ไม่มีใน hexa — ตั้งเป็น 'bank' ถ้าอยากให้ไหลเข้าธนาคารแทน
}

-- ==========================================
-- กลุ่มสิทธิ์ (group)
-- ==========================================
-- VORP เก็บสิทธิ์เป็นสตริงบนตัวละคร (Character.group) ส่วน hexa ใช้ ace
-- 'hexacore.<perm>' ตารางนี้แปลงสองทาง
-- hexa ace -> VORP group (ไล่จากบนลงล่าง เจอตัวแรกที่ผ่านก็ใช้ตัวนั้น)
BridgeConfig.GroupFromPermission = {
    { permission = 'admin', group = 'admin' },
    { permission = 'staff', group = 'moderator' },
}

-- VORP group -> hexa ace (ใช้ตอนสคริปต์เรียก Character.setGroup)
BridgeConfig.PermissionFromGroup = {
    admin     = 'admin',
    superadmin = 'admin',
    moderator = 'staff',
    mod       = 'staff',
    user      = false,   -- false = ถอดสิทธิ์ทั้งหมด
}

-- group ที่ใช้เมื่อผู้เล่นไม่มี ace อะไรเลย
BridgeConfig.DefaultGroup = 'user'

-- ==========================================
-- อื่น ๆ
-- ==========================================
-- ค่า Core.maxCharacters ที่รายงานให้สคริปต์ VORP
-- (ควรตั้งให้ตรงกับ hexa_multicharacter/config.lua > Config.MaxCharacterSlots)
BridgeConfig.MaxCharacters = 5

-- ประเภท toast ที่ใช้กับ Notify แต่ละแบบของ VORP
BridgeConfig.NotifyTypes = {
    RightTip     = 'info',
    Tip          = 'info',
    Left         = 'info',
    LeftRotate   = 'info',
    Top          = 'info',
    SimpleTop    = 'info',
    Center       = 'primary',
    BottomRight  = 'info',
    Objective    = 'primary',
    Avanced      = 'info',
    Advanced     = 'info',
}

-- true = พิมพ์ log ทุกครั้งที่สคริปต์เรียกของที่ bridge ยังแปลงให้ไม่ได้
BridgeConfig.Debug = false
