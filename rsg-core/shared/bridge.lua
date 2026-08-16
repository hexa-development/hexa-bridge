--[[
    rsg-core (compat bridge) — shared layer
    ---------------------------------------------------------------------
    resource นี้ "ไม่ใช่" rsg-core ตัวจริง แต่เป็นตัวแปลง (shim) ที่แปะชื่อ
    rsg-core ไว้ เพื่อให้สคริปต์ที่เขียนมาสำหรับ RSG Framework ทำงานบน
    hexa_core ได้โดยไม่ต้องแก้ตัวสคริปต์เอง

    สิ่งที่ resource นี้ให้:
      exports['rsg-core']:GetCoreObject()   -> RSGCore object (แปลงจาก HexaCore)
      RSGCore:* events                      -> ส่งต่อไป/มาจาก HexaCore:* events
      @rsg-core/shared/locale.lua           -> คลาส Locale (Lang:t) แบบเดียวกับ qb/rsg

    ไฟล์นี้เป็นชั้นล่างสุด โหลดก่อนทุกไฟล์ เพราะ client/server ใช้ Bridge.* ตอนโหลด
]]

Bridge = Bridge or {}

local IS_SERVER = IsDuplicityVersion()
local RESOURCE  = GetCurrentResourceName()

-------------------------------------------------------------------
-- core object ของ hexa_core
-------------------------------------------------------------------
-- exports['hexa_core']:GetCoreObject() ข้าม resource boundary จึงคืน "สำเนา
-- msgpack ณ วินาทีนั้น" ไม่ใช่ reference จริง ตอน resource นี้เพิ่งสตาร์ท
-- hexa_core อาจยังรอ MySQL.ready เติม Shared.Items อยู่ สำเนาที่ได้ตอนนั้นจึง
-- เป็นแคตตาล็อกว่างและจะค้างว่างทั้ง session ถ้าไม่ดึงใหม่
--
-- hexa_core ประกาศทุกครั้งที่ของเปลี่ยน (HexaCore:Server:UpdateObject /
-- HexaCore:Client:UpdateObject) จึงดึงใหม่ตรงนั้น แล้วทุกจุดที่ต้องใช้เรียก
-- Bridge.Core() เพื่อได้สำเนาล่าสุดเสมอ
local cached

local function refresh()
    local ok, core = pcall(function() return exports['hexa_core']:GetCoreObject() end)
    if ok and type(core) == 'table' then cached = core end
    return cached
end

refresh()

AddEventHandler(IS_SERVER and 'HexaCore:Server:UpdateObject' or 'HexaCore:Client:UpdateObject', refresh)

if not IS_SERVER then
    -- ฝั่ง client แคตตาล็อกมากับ HexaCore:Client:SharedUpdate ซึ่ง hexa_core
    -- ส่งตอน RequestSpawn เท่านั้น = หลังหน้าโหลด + หน้าเลือกตัวละคร
    AddEventHandler('HexaCore:Client:SharedUpdate', refresh)
    AddEventHandler('HexaCore:Client:OnPlayerLoaded', refresh)
end

local function catalogueReady(core)
    return core and core.Shared and core.Shared.Items and next(core.Shared.Items) ~= nil
end

-- ทางถอยตอนบูตเย็น: แคตตาล็อกอาจมาถึงก่อน handler ข้างบนถูกลงทะเบียน
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

--- สร้าง wrapper แบบ late-bind ให้ HexaCore.Functions.<name>
--- ผูกชื่อไว้เฉย ๆ แล้วค่อยหาตัวจริงตอนถูกเรียก -> รอด hexa_core restart
---@param name string
---@return function
function Bridge.Fn(name)
    return function(...)
        local core = Bridge.Core()
        local f = core and core.Functions and core.Functions[name]
        if not f then
            print(('^3[%s]^7 HexaCore.Functions.%s does not exist (called through RSGCore)')
                :format(RESOURCE, tostring(name)))
            return
        end
        return f(...)
    end
end

-------------------------------------------------------------------
-- ตัวช่วยทั่วไป
-------------------------------------------------------------------

--- คัดลอกตารางชั้นเดียว
--- ห้ามใช้ deepcopy กับของที่มาจากข้าม resource: funcref คือ table + metatable
--- __call การก็อปแบบลึกจะทำ metatable หลุด แล้วเรียกฟังก์ชันนั้นไม่ได้อีกเลย
---@param t table?
---@return table
function Bridge.Shallow(t)
    local r = {}
    if type(t) == 'table' then
        for k, v in pairs(t) do r[k] = v end
    end
    return r
end

--- ตรวจว่าค่าที่ได้มาเรียกได้ไหม (funcref ข้าม resource = table + __call)
---@param v any
---@return boolean
function Bridge.Callable(v)
    local t = type(v)
    if t == 'function' then return true end
    if t ~= 'table' then return false end
    local mt = getmetatable(v)
    return (mt and mt.__call) ~= nil or rawget(v, '__cfx_functionReference') ~= nil
end

-------------------------------------------------------------------
-- แปลงรูปแบบการแจ้งเตือน
-------------------------------------------------------------------
-- qb/rsg:  Notify(source, text, type, length)  / client: Notify(text, type, length)
--          text เป็น string หรือ { text = ..., caption = ... }
-- hexa:    Notify(source, { title, description, type, duration })
local NOTIFY_TYPES = {
    primary   = 'primary',
    success   = 'success',
    error     = 'error',
    warning   = 'warning',
    warn      = 'warning',
    info      = 'info',
    inform    = 'info',
    police    = 'info',
    ambulance = 'info',
}

---@param text string|table
---@param ntype string?
---@param length number?
---@return table
function Bridge.NotifyData(text, ntype, length)
    local title, description

    if type(text) == 'table' then
        title       = text.text or text.title or ''
        description = text.caption or text.description
    else
        title = tostring(text or '')
    end

    return {
        title       = title,
        description = description,
        type        = NOTIFY_TYPES[tostring(ntype or 'primary'):lower()] or 'primary',
        duration    = tonumber(length) or 5000,
    }
end

-------------------------------------------------------------------
-- คิว callback (ใช้ร่วมกันทั้ง client และ server)
-------------------------------------------------------------------
-- rsg/qb เก็บ callback ไว้ช่องเดียวต่อชื่อ แล้วลบทิ้งหลังตอบกลับครั้งแรก
-- ถ้าเรียกชื่อเดิมซ้อนกันสองครั้ง อันแรกจะถูกทับหายเงียบ ๆ
-- ตรงนี้เก็บเป็นคิว FIFO ต่อชื่อแทน — ใช้ event/พารามิเตอร์ชุดเดิมทุกอย่าง
-- (wire-compatible) แต่ไม่มีอาการทับกันอีก
---@return table
function Bridge.NewQueue()
    local q = { store = {} }

    ---@param name string
    ---@param cb any
    ---@param meta any? ข้อมูลเสริมที่อยากผูกไปกับรายการนี้ (เช่น source)
    function q.push(name, cb, meta)
        local list = q.store[name]
        if not list then
            list = {}
            q.store[name] = list
        end
        list[#list + 1] = { cb = cb, meta = meta }
    end

    --- ดึงรายการแรกที่ตรงเงื่อนไขออกมา (ถ้าไม่ส่ง match ก็เอาตัวแรกสุด)
    ---@param name string
    ---@param match function? fun(meta): boolean
    ---@return any cb, any meta
    function q.pop(name, match)
        local list = q.store[name]
        if not list or #list == 0 then return nil end

        for i = 1, #list do
            if not match or match(list[i].meta) then
                local entry = table.remove(list, i)
                if #list == 0 then q.store[name] = nil end
                return entry.cb, entry.meta
            end
        end

        return nil
    end

    --- ทิ้งทุกรายการที่ตรงเงื่อนไข (ใช้ตอนผู้เล่นหลุด)
    ---@param match function fun(meta): boolean
    function q.drop(match)
        for name, list in pairs(q.store) do
            for i = #list, 1, -1 do
                if match(list[i].meta) then table.remove(list, i) end
            end
            if #list == 0 then q.store[name] = nil end
        end
    end

    return q
end
