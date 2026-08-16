--[[
    vorp_core (compat bridge) — ฝั่ง client
    ---------------------------------------------------------------------
        local Core = exports.vorp_core:GetCore()
        -- หรือ
        TriggerEvent('getCore', function(core) Core = core end)

        Core.NotifyRightTip('ข้อความ', 4000)
        Core.Callback.TriggerAsync('ชื่อ', function(result) end, ...)
        local result = Core.Callback.TriggerAwait('ชื่อ', ...)
]]

local Core = {}

-------------------------------------------------------------------
-- การแจ้งเตือน
-------------------------------------------------------------------
-- VORP มีฟังก์ชันสิบกว่าตัวแยกตามตำแหน่งบนจอ ที่นี่ยุบลงมาเป็น toast ของ
-- hexa_notify ตัวเดียว แต่คงชื่อทุกตัวไว้ให้สคริปต์เรียกได้โดยไม่ error
local function push(title, description, kind, duration)
    TriggerEvent('HexaCore:Notify',
        Bridge.NotifyData(title, description, BridgeConfig.NotifyTypes[kind] or 'info', duration))
end

function Core.NotifyRightTip(text, duration)                 push(text, nil, 'RightTip', duration) end
function Core.NotifyTip(text, duration)                      push(text, nil, 'Tip', duration) end
function Core.NotifyObjective(text, duration)                push(text, nil, 'Objective', duration) end
function Core.NotifyCenter(text, duration)                   push(text, nil, 'Center', duration) end
function Core.NotifyBottomRight(text, duration)              push(text, nil, 'BottomRight', duration) end
function Core.NotifyTop(text, _location, duration)           push(text, nil, 'Top', duration) end
function Core.NotifySimpleTop(title, subtitle, duration)     push(title, subtitle, 'SimpleTop', duration) end
function Core.NotifyLeft(title, subtitle, _d, _i, duration)  push(title, subtitle, 'Left', duration) end
function Core.NotifyLeftRotate(title, subtitle, _d, _i, duration) push(title, subtitle, 'LeftRotate', duration) end
function Core.NotifyAvanced(text, _dict, _icon, _color, duration) push(text, nil, 'Avanced', duration) end
Core.NotifyAdvanced = Core.NotifyAvanced

function Core.NotifyDeadPlayer()
    push('You are dead', nil, 'Center', 5000)
end

-------------------------------------------------------------------
-- Callbacks
-------------------------------------------------------------------
-- ใช้ request id ต่อคำขอ ไม่ได้ผูกกับ "ชื่อ callback" อย่างเดียวเหมือนต้นฉบับ
-- ยิงชื่อเดิมซ้อนกันหลายครั้งพร้อมกันจึงไม่ทับกัน
local CB_TIMEOUT = 15000

local pending  = {}
local nextId   = 0
local clientCallbacks = {}

local function newRequest()
    nextId = nextId + 1
    local id = nextId

    return id
end

RegisterNetEvent('vorp_core:bridge:cb:response', function(reqId, ...)
    local entry = pending[reqId]
    if not entry then return end
    pending[reqId] = nil

    if entry.promise then
        entry.promise:resolve(table.pack(...))
    elseif Bridge.Callable(entry.cb) then
        entry.cb(...)
    end
end)

Core.Callback = {}

--- ยิงไปหา callback ฝั่ง server แล้วรับผลผ่าน cb
---@param name string
---@param cb function
function Core.Callback.TriggerAsync(name, cb, ...)
    local id = newRequest()
    pending[id] = { cb = cb }

    SetTimeout(CB_TIMEOUT, function()
        if pending[id] then
            pending[id] = nil
            if Bridge.Callable(cb) then cb() end
        end
    end)

    TriggerServerEvent('vorp_core:bridge:cb:request', name, id, ...)
end

--- แบบรอผลตรง ๆ (ต้องเรียกในเธรด)
---@param name string
---@return any
function Core.Callback.TriggerAwait(name, ...)
    local id = newRequest()
    local p  = promise.new()
    pending[id] = { promise = p }

    SetTimeout(CB_TIMEOUT, function()
        if pending[id] then
            pending[id] = nil
            p:resolve(table.pack())
        end
    end)

    TriggerServerEvent('vorp_core:bridge:cb:request', name, id, ...)

    local res = Citizen.Await(p)
    return table.unpack(res, 1, res.n)
end

-- บางสคริปต์ลงทะเบียน callback ฝั่ง client ไว้ให้ server เรียก
function Core.Callback.Register(name, fn)
    clientCallbacks[name] = fn
end

RegisterNetEvent('vorp_core:bridge:cb:clientRequest', function(name, reqId, ...)
    local fn = clientCallbacks[name]
    if not fn then
        return TriggerServerEvent('vorp_core:bridge:cb:clientResponse', reqId)
    end

    fn(function(...)
        TriggerServerEvent('vorp_core:bridge:cb:clientResponse', reqId, ...)
    end, ...)
end)

-------------------------------------------------------------------
-- Event ที่สคริปต์ VORP ดักฟัง
-------------------------------------------------------------------
-- เปิดชื่อ event ไว้ล่วงหน้า: ถ้าไม่มี resource ไหน RegisterNetEvent ชื่อนั้นเลย
-- เซิร์ฟจะทิ้ง event จาก server ทิ้งเงียบ ๆ แล้ว AddEventHandler ของ resource
-- อื่นจะไม่ได้ยินอะไรทั้งนั้น
local passiveEvents = {
    'vorp:SelectedCharacter',
    'vorp:playerSpawn',
    'vorp:updateCharUi',
    'vorp:playerDropped',
}

for i = 1, #passiveEvents do
    RegisterNetEvent(passiveEvents[i])
end

-------------------------------------------------------------------
-- ส่งออก
-------------------------------------------------------------------
exports('GetCore', function()
    return Core
end)

AddEventHandler('getCore', function(cb)
    if not Bridge.Callable(cb) then return end
    cb(Core)
end)
