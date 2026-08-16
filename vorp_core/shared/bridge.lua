--[[
    vorp_core (compat bridge) — shared layer
    ---------------------------------------------------------------------
    resource นี้ "ไม่ใช่" VORP Core ตัวจริง แต่เป็นตัวแปลง (shim) ที่แปะชื่อ
    vorp_core ไว้ เพื่อให้สคริปต์ที่เขียนมาสำหรับ VORP Framework ทำงานบน
    hexa_core ได้โดยไม่ต้องแก้ตัวสคริปต์เอง

    สิ่งที่ resource นี้ให้:
      exports.vorp_core:GetCore()          -> Core object แบบ VORP
      TriggerEvent('getCore', cb)          -> ทางเรียก Core แบบดั้งเดิมของ VORP
      Core.getUser(src).getUsedCharacter   -> Character ที่แปลงจาก hexa PlayerData
      vorp:SelectedCharacter / vorp:playerSpawn events

    ไฟล์นี้เป็นชั้นล่างสุด โหลดก่อนทุกไฟล์
]]

Bridge = Bridge or {}

local IS_SERVER = IsDuplicityVersion()
local RESOURCE  = GetCurrentResourceName()

-------------------------------------------------------------------
-- core object ของ hexa_core
-------------------------------------------------------------------
-- exports['hexa_core']:GetCoreObject() ข้าม resource boundary จึงคืน "สำเนา
-- msgpack ณ วินาทีนั้น" ไม่ใช่ reference จริง ต้องดึงใหม่ทุกครั้งที่ hexa
-- ประกาศว่ามีอะไรเปลี่ยน ไม่งั้นจะค้างอยู่กับสำเนาว่างตอนบูตทั้ง session
local cached

local function refresh()
    local ok, core = pcall(function() return exports['hexa_core']:GetCoreObject() end)
    if ok and type(core) == 'table' then cached = core end
    return cached
end

refresh()

AddEventHandler(IS_SERVER and 'HexaCore:Server:UpdateObject' or 'HexaCore:Client:UpdateObject', refresh)

if not IS_SERVER then
    AddEventHandler('HexaCore:Client:SharedUpdate', refresh)
    AddEventHandler('HexaCore:Client:OnPlayerLoaded', refresh)
end

local function catalogueReady(core)
    return core and core.Shared and core.Shared.Items and next(core.Shared.Items) ~= nil
end

CreateThread(function()
    for _ = 1, 30 do
        Wait(1000)
        if catalogueReady(refresh()) then return end
    end
end)

--- คืน core object ชุดล่าสุดของ hexa_core
---@return table?
function Bridge.Core()
    return cached or refresh()
end

--- เรียก HexaCore.Functions.<name> แบบหาตัวจริงตอนเรียก (รอด hexa_core restart)
---@param name string
---@return any
function Bridge.CallFn(name, ...)
    local core = Bridge.Core()
    local f    = core and core.Functions and core.Functions[name]
    if not f then
        print(('^3[%s]^7 HexaCore.Functions.%s does not exist'):format(RESOURCE, tostring(name)))
        return nil
    end
    return f(...)
end

-------------------------------------------------------------------
-- ตัวช่วยทั่วไป
-------------------------------------------------------------------

--- คัดลอกตารางชั้นเดียว
--- ห้าม deepcopy ของที่ข้าม resource มา: funcref คือ table + metatable __call
--- ถ้าก็อปแบบลึก metatable จะหลุดแล้วเรียกฟังก์ชันนั้นไม่ได้อีก
---@param t table?
---@return table
function Bridge.Shallow(t)
    local r = {}
    if type(t) == 'table' then
        for k, v in pairs(t) do r[k] = v end
    end
    return r
end

---@param v any
---@return boolean
function Bridge.Callable(v)
    local t = type(v)
    if t == 'function' then return true end
    if t ~= 'table' then return false end
    local mt = getmetatable(v)
    return (mt and mt.__call) ~= nil or rawget(v, '__cfx_functionReference') ~= nil
end

local warned = {}

---@param key string
---@param message string
function Bridge.WarnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    print(('^3[%s]^7 %s'):format(RESOURCE, message))
end

-------------------------------------------------------------------
-- แปลงการแจ้งเตือนของ VORP -> hexa
-------------------------------------------------------------------
-- VORP มีฟังก์ชันแจ้งเตือนสิบกว่าตัวแยกตามตำแหน่ง/แอนิเมชันบนจอ (RightTip,
-- Left, Objective, SimpleTop, ...) hexa มีระบบ toast ตัวเดียว จึงยุบทุกตัวลงมา
-- เหลือรูปแบบเดียวกัน แต่ยังคงชื่อฟังก์ชันครบเพื่อไม่ให้สคริปต์เรียกแล้ว error
---@param title string?
---@param description string?
---@param ntype string?
---@param duration number?
---@return table
function Bridge.NotifyData(title, description, ntype, duration)
    return {
        title       = tostring(title or ''),
        description = description and tostring(description) or nil,
        type        = ntype or 'info',
        duration    = tonumber(duration) or 5000,
    }
end
