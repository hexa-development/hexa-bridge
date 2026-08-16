--[[
    vorp_core (compat bridge) — ฝั่ง server
    ---------------------------------------------------------------------
    สร้าง Core object ทรง VORP ที่ข้างในเรียก hexa_core ทั้งหมด สคริปต์ VORP
    จึงใช้ได้ทั้งสองแบบตามที่เคยเขียนมา:

        local Core = exports.vorp_core:GetCore()
        -- หรือแบบดั้งเดิม
        TriggerEvent('getCore', function(core) Core = core end)

        local User      = Core.getUser(source)
        local Character = User.getUsedCharacter
        Character.addCurrency(0, 100)
]]

local RESOURCE = GetCurrentResourceName()

local Core = {}
Core.maxCharacters = BridgeConfig.MaxCharacters

-------------------------------------------------------------------
-- แปลงสกุลเงิน / กลุ่มสิทธิ์
-------------------------------------------------------------------
---@param ctype number|string VORP: 0 = money, 1 = gold, 2 = rol
---@return string? ชื่อช่องเงินของ hexa
local function currencyOf(ctype)
    local key    = tonumber(ctype) or 0
    local mapped = BridgeConfig.Currency[key]

    if mapped == false or mapped == nil then
        Bridge.WarnOnce('currency:' .. tostring(key),
            ('currency id %s is not mapped in hexa_core - set BridgeConfig.Currency in vorp_core/config.lua')
                :format(tostring(key)))
        return nil
    end

    return mapped
end

---@param src number
---@return string
local function groupOf(src)
    local list = BridgeConfig.GroupFromPermission
    for i = 1, #list do
        if Bridge.CallFn('HasPermission', src, list[i].permission) then
            return list[i].group
        end
    end
    return BridgeConfig.DefaultGroup
end

---@param src number
---@param group string
local function applyGroup(src, group)
    local perm = BridgeConfig.PermissionFromGroup[tostring(group or ''):lower()]

    if perm == nil then
        Bridge.WarnOnce('group:' .. tostring(group),
            ("permission group '%s' is not in the mapping table - set BridgeConfig.PermissionFromGroup in vorp_core/config.lua")
                :format(tostring(group)))
        return
    end

    if perm == false then
        -- ส่ง permission เป็น nil = hexa ถอดทุกระดับสิทธิ์ออกจากผู้เล่นคนนี้
        Bridge.CallFn('RemovePermission', src, nil)
        return
    end

    Bridge.CallFn('AddPermission', src, perm)
end

-------------------------------------------------------------------
-- Character
-------------------------------------------------------------------
-- VORP เก็บทุกอย่างไว้บนตัวละครก้อนเดียว ส่วน hexa แยกเป็น charinfo / job /
-- money / metadata ตรงนี้คือจุดแปลงหลักของทั้ง bridge
--
-- ⚠️ ค่าที่อ่านได้เป็น "สำเนา ณ ตอนเรียก getUser" เหมือนกับ VORP ตัวจริง
-- (ข้าม resource boundary ก็เป็นสำเนาทั้งคู่) สคริปต์จึงต้องเรียก
-- Core.getUser(src) ใหม่ทุกครั้งก่อนอ่านค่าเงิน — ซึ่งสคริปต์ VORP ทำอยู่แล้ว
local function buildCharacter(src, hp)
    local pd = hp.PlayerData or {}
    local F  = hp.Functions

    local charinfo = pd.charinfo or {}
    local money    = pd.money    or {}
    local meta     = pd.metadata or {}
    local job      = pd.job      or {}
    local grade    = job.grade   or {}

    local ch = {
        -- ข้อมูลประจำตัว
        charIdentifier = tonumber(pd.citizenid) or pd.citizenid,
        identifier     = pd.license,
        id             = tonumber(pd.citizenid) or pd.citizenid,
        group          = groupOf(src),

        -- ชื่อ
        firstname      = charinfo.firstname,
        lastname       = charinfo.lastname,
        nickname       = ('%s %s'):format(tostring(charinfo.firstname or ''), tostring(charinfo.lastname or '')),
        charDescription = '',

        -- อาชีพ
        job            = job.name,
        jobGrade       = tonumber(grade.level) or 0,
        jobLabel       = job.label,

        -- เงิน
        money          = tonumber(money[BridgeConfig.Currency[0] or 'cash']) or 0,
        gold           = tonumber(money[BridgeConfig.Currency[1] or 'gold']) or 0,
        rol            = BridgeConfig.Currency[2] and (tonumber(money[BridgeConfig.Currency[2]]) or 0) or 0,

        -- สถานะ
        xp             = tonumber(meta.xp) or 0,
        hours          = tonumber(meta.playtime) or 0,
        isdead         = meta.isdead and true or false,
        healthOuter    = tonumber(meta.health)  or 100,
        healthInner    = tonumber(meta.health)  or 100,
        staminaOuter   = tonumber(meta.stamina) or 100,
        staminaInner   = tonumber(meta.stamina) or 100,
        coords         = pd.position,
        age            = tonumber(meta.age) or 0,
        gender         = (charinfo.gender == 1) and 'female' or 'male',
        walk           = meta.walk or '',

        -- ⚠️ สองช่องนี้เป็นรูปแบบ skin/comps ของ VORP โดยเฉพาะ
        -- สแตกนี้ใช้ hexa_skin ซึ่งเก็บคนละฟอร์แมต จึงส่งค่าว่างไป
        -- สคริปต์แต่งตัวของ VORP จะใช้ไม่ได้ (ดู README)
        skinPlayer     = '',
        compPlayer     = '',
        comps          = {},

        -- VORP เก็บของในตัวละครเอง ส่วนสแตกนี้อยู่ที่ hexa_inventory
        inventory      = {},
        status         = meta.status or {},
    }

    -----------------------------------------------------------
    -- เงิน
    -----------------------------------------------------------
    ch.addCurrency = function(ctype, amount)
        local account = currencyOf(ctype)
        if not account then return false end
        return F.AddMoney(account, tonumber(amount) or 0, 'vorp_core:addCurrency') and true or false
    end

    ch.removeCurrency = function(ctype, amount)
        local account = currencyOf(ctype)
        if not account then return false end
        return F.RemoveMoney(account, tonumber(amount) or 0, 'vorp_core:removeCurrency') and true or false
    end

    ch.setCurrency = function(ctype, amount)
        local account = currencyOf(ctype)
        if not account then return false end
        return F.SetMoney(account, tonumber(amount) or 0, 'vorp_core:setCurrency') and true or false
    end

    ch.getCurrency = function(ctype)
        local account = currencyOf(ctype)
        if not account then return 0 end
        return tonumber(F.GetMoney(account)) or 0
    end

    -----------------------------------------------------------
    -- อาชีพ
    -----------------------------------------------------------
    ch.setJob = function(newJob)
        return F.SetJob(newJob, ch.jobGrade)
    end

    ch.setJobGrade = function(newGrade)
        return F.SetJob(ch.job, newGrade)
    end

    ch.setJobLabel = function()
        -- hexa อ่าน label จากตาราง jobs ในฐานข้อมูล ไม่ได้เก็บไว้ที่ตัวละคร
        Bridge.WarnOnce('setJobLabel',
            'script called Character.setJobLabel - hexa_core keeps the label on the jobs table, not on the character, so this is a no-op')
        return false
    end

    ch.setJobDuty = function(onduty)
        return F.SetJobDuty(onduty and true or false)
    end

    -----------------------------------------------------------
    -- สิทธิ์
    -----------------------------------------------------------
    ch.setGroup = function(group)
        applyGroup(src, group)
        ch.group = group
    end

    -----------------------------------------------------------
    -- ค่าประสบการณ์ / สถานะ
    -----------------------------------------------------------
    ch.addXp = function(amount)
        local value = (tonumber(meta.xp) or 0) + (tonumber(amount) or 0)
        F.SetMetaData('xp', value)
        ch.xp = value
    end

    ch.removeXp = function(amount)
        local value = math.max((tonumber(meta.xp) or 0) - (tonumber(amount) or 0), 0)
        F.SetMetaData('xp', value)
        ch.xp = value
    end

    ch.setXp = function(amount)
        local value = math.max(tonumber(amount) or 0, 0)
        F.SetMetaData('xp', value)
        ch.xp = value
    end

    ch.setHealth = function(value)
        F.SetMetaData('health', tonumber(value) or 0)
    end
    ch.setHealthOuter = ch.setHealth
    ch.setHealthInner = ch.setHealth

    ch.setStamina = function(value)
        F.SetMetaData('stamina', tonumber(value) or 0)
    end
    ch.setStaminaOuter = ch.setStamina
    ch.setStaminaInner = ch.setStamina

    ch.setDead = function(state)
        F.SetMetaData('isdead', state and true or false)
    end

    ch.setHours = function(value)
        F.SetMetaData('playtime', tonumber(value) or 0)
    end

    -----------------------------------------------------------
    -- อื่น ๆ
    -----------------------------------------------------------
    ch.updateCharUi = function()
        F.UpdatePlayerData()
        TriggerClientEvent('vorp:updateCharUi', src)
    end

    ch.saveCharacter = function()
        return F.Save()
    end

    -- ช่องที่เป็นของระบบเลือกตัวละครของ VORP โดยเฉพาะ — สแตกนี้ใช้
    -- hexa_multicharacter ทำหน้าที่นั้นแทน จึงไม่ทำอะไรแต่ต้องเรียกได้
    ch.setSkin = function()
        Bridge.WarnOnce('setSkin', 'script called Character.setSkin - this stack uses hexa_skin, a different format from VORP, so this is a no-op')
        return false
    end
    ch.setComps = ch.setSkin

    return ch
end

-------------------------------------------------------------------
-- User
-------------------------------------------------------------------
---@param src number|string
---@return table?
function Core.getUser(src)
    src = tonumber(src)
    if not src or src <= 0 then return nil end

    local hp = Bridge.CallFn('GetPlayer', src)
    if type(hp) ~= 'table' or type(hp.Functions) ~= 'table' then return nil end

    local character = buildCharacter(src, hp)

    local user = {
        source            = src,
        identifier        = hp.PlayerData and hp.PlayerData.license,

        -- ⚠️ ทั้งสองช่องนี้เป็น "ค่า" ไม่ใช่ฟังก์ชัน — VORP เขียนแบบไม่มีวงเล็บ
        --    (User.getUsedCharacter.money) bridge จึงต้องสร้างไว้ล่วงหน้าเหมือนกัน
        getUsedCharacter  = character,
        getUserCharacters = { character },
        getGroup          = character.group,
        numOfCharacters   = 1,
    }

    user.setGroup = function(group)
        character.setGroup(group)
        user.getGroup = group
    end

    user.getNumOfCharacters = function()
        return 1
    end

    -- ระบบเลือก/สร้าง/ลบตัวละครเป็นหน้าที่ของ hexa_multicharacter
    -- ปล่อยให้เรียกได้แต่ไม่ทำอะไร เพื่อไม่ให้สคริปต์ที่เรียกพังทั้งไฟล์
    local function unsupported(name)
        return function()
            Bridge.WarnOnce('user:' .. name,
                ('script called User.%s - character slot management lives in hexa_multicharacter, so this is a no-op'):format(name))
            return false
        end
    end

    user.setUsedCharacter = unsupported('setUsedCharacter')
    user.addCharacter     = unsupported('addCharacter')
    user.delCharacter     = unsupported('delCharacter')

    return user
end

---@return table [source] = User
function Core.getUsers()
    local users = {}
    local list  = Bridge.CallFn('GetPlayers')
    if type(list) ~= 'table' then return users end

    for i = 1, #list do
        local user = Core.getUser(list[i])
        if user then users[list[i]] = user end
    end

    return users
end

-- ชื่อพ้องที่บางเวอร์ชันของ VORP ใช้
Core.GetUser  = Core.getUser
Core.GetUsers = Core.getUsers

-------------------------------------------------------------------
-- การแจ้งเตือน
-------------------------------------------------------------------
-- VORP แยกฟังก์ชันตามตำแหน่ง/แอนิเมชันบนจอ hexa มี toast แบบเดียว
-- จึงยุบทุกตัวลงมาที่ HexaCore:Notify แต่คงชื่อไว้ครบเพื่อไม่ให้สคริปต์ error
local function push(src, title, description, kind, duration)
    src = tonumber(src)
    if not src or src <= 0 then return end
    TriggerClientEvent('HexaCore:Notify', src,
        Bridge.NotifyData(title, description, BridgeConfig.NotifyTypes[kind] or 'info', duration))
end

function Core.NotifyRightTip(src, text, duration)               push(src, text, nil, 'RightTip', duration) end
function Core.NotifyTip(src, text, duration)                    push(src, text, nil, 'Tip', duration) end
function Core.NotifyObjective(src, text, duration)              push(src, text, nil, 'Objective', duration) end
function Core.NotifyCenter(src, text, duration)                 push(src, text, nil, 'Center', duration) end
function Core.NotifyBottomRight(src, text, duration)            push(src, text, nil, 'BottomRight', duration) end
function Core.NotifyTop(src, text, _location, duration)         push(src, text, nil, 'Top', duration) end
function Core.NotifySimpleTop(src, title, subtitle, duration)   push(src, title, subtitle, 'SimpleTop', duration) end
function Core.NotifyLeft(src, title, subtitle, _d, _i, duration) push(src, title, subtitle, 'Left', duration) end
function Core.NotifyLeftRotate(src, title, subtitle, _d, _i, duration) push(src, title, subtitle, 'LeftRotate', duration) end
function Core.NotifyAvanced(src, text, _dict, _icon, _color, duration) push(src, text, nil, 'Avanced', duration) end
Core.NotifyAdvanced = Core.NotifyAvanced

function Core.NotifyDeadPlayer(src)
    push(src, 'You are dead', nil, 'Center', 5000)
end

-------------------------------------------------------------------
-- Callbacks
-------------------------------------------------------------------
-- ใช้ช่องทาง event ของ bridge เอง (มี request id) แทนโปรโตคอลภายในของ VORP
-- สคริปต์เรียกผ่าน Core.Callback.* เหมือนเดิมทุกอย่าง จึงไม่ต้องรู้ว่าเปลี่ยน
local callbacks = {}

Core.Callback = {}

---@param name string
---@param fn function fun(source, cb, ...)
function Core.Callback.Register(name, fn)
    callbacks[name] = fn
end

Core.addRpcCallback  = Core.Callback.Register
Core.RegisterCallback = Core.Callback.Register

RegisterNetEvent('vorp_core:bridge:cb:request', function(name, reqId, ...)
    local src = source
    local fn  = callbacks[name]

    -- ตอบกลับเสมอแม้ไม่มี handler ไม่งั้นฝั่ง client รอจนหมด timeout
    if not fn then
        if BridgeConfig.Debug then
            print(('^3[%s]^7 callback "%s" not found'):format(RESOURCE, tostring(name)))
        end
        return TriggerClientEvent('vorp_core:bridge:cb:response', src, reqId)
    end

    local ok, err = pcall(fn, src, function(...)
        TriggerClientEvent('vorp_core:bridge:cb:response', src, reqId, ...)
    end, ...)

    if not ok then
        print(('^1[%s]^7 callback "%s" error: %s'):format(RESOURCE, tostring(name), tostring(err)))
        TriggerClientEvent('vorp_core:bridge:cb:response', src, reqId)
    end
end)

-- server -> client callback (บางสคริปต์ลงทะเบียนฝั่ง client ไว้ให้ server เรียก)
local clientPending, clientNextId = {}, 0

---@param name string
---@param src number
---@param cb function
function Core.Callback.TriggerClientAsync(name, src, cb, ...)
    src = tonumber(src)
    if not src or src <= 0 then return end

    clientNextId = clientNextId + 1
    local id = clientNextId
    clientPending[id] = { cb = cb, src = src }

    SetTimeout(15000, function()
        if clientPending[id] then
            clientPending[id] = nil
            if Bridge.Callable(cb) then cb() end
        end
    end)

    TriggerClientEvent('vorp_core:bridge:cb:clientRequest', src, name, id, ...)
end

RegisterNetEvent('vorp_core:bridge:cb:clientResponse', function(reqId, ...)
    local entry = clientPending[reqId]
    -- ผูก request id กับ source ที่ยิงไป กัน client อื่นแอบตอบแทน
    if not entry or entry.src ~= source then return end
    clientPending[reqId] = nil
    if Bridge.Callable(entry.cb) then entry.cb(...) end
end)

AddEventHandler('playerDropped', function()
    local src = source
    for id, entry in pairs(clientPending) do
        if entry.src == src then clientPending[id] = nil end
    end
end)

-------------------------------------------------------------------
-- Webhook
-------------------------------------------------------------------
--- @param title string
--- @param webhook string URL ของ Discord webhook
--- @param description string
function Core.AddWebhook(title, webhook, description, colour, name, logo, footerlogo, avatar)
    if type(webhook) ~= 'string' or webhook == '' then return end

    local embed = {{
        color       = colour or 0,
        title       = tostring(title or ''),
        description = tostring(description or ''),
        footer      = { text = os.date('%c'), icon_url = footerlogo or nil },
        thumbnail   = logo and { url = logo } or nil,
    }}

    PerformHttpRequest(webhook, function() end, 'POST', json.encode({
        username   = name or 'hexa',
        avatar_url = avatar or nil,
        embeds     = embed,
    }), { ['Content-Type'] = 'application/json' })
end

-------------------------------------------------------------------
-- ส่งต่อ event: HexaCore:* -> vorp:*
-------------------------------------------------------------------
AddEventHandler('HexaCore:Server:PlayerLoaded', function(Player)
    local src = Player and Player.PlayerData and Player.PlayerData.source
    if not src then return end

    local user = Core.getUser(src)
    if not user then return end

    TriggerEvent('vorp:SelectedCharacter', src, user.getUsedCharacter)
    TriggerClientEvent('vorp:SelectedCharacter', src, user.getUsedCharacter.charIdentifier)
end)

RegisterNetEvent('HexaCore:Server:OnPlayerLoaded', function()
    local src = source
    TriggerEvent('vorp:playerSpawn', src)
    TriggerClientEvent('vorp:playerSpawn', src)
end)

AddEventHandler('HexaCore:Server:PlayerDropped', function(Player)
    local src = Player and Player.PlayerData and Player.PlayerData.source
    if not src then return end
    TriggerEvent('vorp:playerDropped', src)
end)

AddEventHandler('HexaCore:Server:OnJobUpdate', function(src, job)
    TriggerEvent('vorp:setJob', src, job and job.name, job and job.grade and job.grade.level)
end)

-------------------------------------------------------------------
-- ส่งออก
-------------------------------------------------------------------
exports('GetCore', function()
    Core.maxCharacters = BridgeConfig.MaxCharacters
    return Core
end)

-- ทางเรียกแบบดั้งเดิมของ VORP:
--     TriggerEvent('getCore', function(core) Core = core end)
-- ตัวสคริปต์ยิง event นี้ตอนโหลด แล้วรอ callback กลับทันที จึงต้องแน่ใจว่า
-- vorp_core สตาร์ทก่อนสคริปต์ที่ใช้ (จัดลำดับใน server.cfg)
AddEventHandler('getCore', function(cb)
    if not Bridge.Callable(cb) then return end
    cb(Core)
end)

CreateThread(function()
    Wait(1000)
    print(('^2[%s]^7 bridge ready - VORP scripts can call exports.vorp_core:GetCore() as usual'):format(RESOURCE))
end)
