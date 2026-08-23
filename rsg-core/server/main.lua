--[[
    rsg-core (compat bridge) — ฝั่ง server
    ---------------------------------------------------------------------
    สร้าง object ชื่อ RSGCore ที่หน้าตาเหมือน rsg-core ตัวจริง แต่ข้างในเรียก
    hexa_core ทั้งหมด สคริปต์ RSG จึงใช้ได้ตามปกติ:

        local RSGCore = exports['rsg-core']:GetCoreObject()
        local Player  = RSGCore.Functions.GetPlayer(source)
        Player.Functions.AddMoney('cash', 100)
]]

local RESOURCE = GetCurrentResourceName()

RSGCore = {
    Config          = {},
    Shared          = {},
    Functions       = {},
    Commands        = {},
    Player          = {},
    Players         = {},
    ServerCallbacks = {},
    ClientCallbacks = {},
    UsableItems     = {},
}

-- ชื่อฟังก์ชันที่เราเขียนเอง — mirror ห้ามทับ
local overridden = {}

local warned = {}
local function warnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    print(('^3[%s]^7 %s'):format(RESOURCE, message))
end

-------------------------------------------------------------------
-- แปลงชื่อประเภทเงิน
-------------------------------------------------------------------
---@param moneytype string
---@return string? ชื่อช่องของ hexa หรือ nil ถ้าไม่รองรับ
local function mapMoneyType(moneytype)
    if type(moneytype) ~= 'string' then return nil end

    local key     = moneytype:lower()
    local mapped  = BridgeConfig.MoneyAliases[key]

    if mapped == false then
        warnOnce('money:' .. key, ("money type '%s' is not mapped in hexa_core - set BridgeConfig.MoneyAliases in rsg-core/config.lua"):format(key))
        return nil
    end

    return mapped or key
end

-------------------------------------------------------------------
-- ห่อ Player object ของ hexa ให้เป็นทรง rsg
-------------------------------------------------------------------
-- hexa PlayerData มีทรงเดียวกับ qb/rsg อยู่แล้ว (citizenid, cid, license, name,
-- money, charinfo, job, metadata, position, items) จึงเติมเฉพาะช่องที่ hexa
-- ไม่มีแล้วสคริปต์ฝั่ง qb/rsg อ่านตรง ๆ โดยไม่เช็ค nil
local function translatePlayerData(pd)
    if type(pd) ~= 'table' then return nil end

    -- pd เป็นสำเนาที่ข้าม resource boundary มาแล้ว แก้ได้เลย ไม่กระทบต้นทาง
    pd.money    = pd.money    or {}
    pd.charinfo = pd.charinfo or {}
    pd.metadata = pd.metadata or {}
    pd.items    = pd.items    or {}
    pd.job      = pd.job      or {}
    pd.job.grade = pd.job.grade or { name = 'No Grade', level = 0, isboss = false }

    if not pd.gang then
        pd.gang = Bridge.Shallow(BridgeConfig.DefaultGang)
        pd.gang.grade = Bridge.Shallow(BridgeConfig.DefaultGang.grade)
    end

    return pd
end

local function inventoryReady()
    return GetResourceState('hexa_inventory') == 'started'
end

---@param hp table? Player object จาก hexa_core
---@return table?
local function wrapPlayer(hp)
    if type(hp) ~= 'table' or type(hp.Functions) ~= 'table' then return nil end

    local F   = hp.Functions
    local src = hp.PlayerData and hp.PlayerData.source

    local self = {
        PlayerData = translatePlayerData(hp.PlayerData),
        Offline    = hp.Offline and true or false,
        Functions  = {},
    }
    local fn = self.Functions

    -- ยกทุกเมธอดของ hexa มาก่อน (รวมของที่ resource อื่นใส่เพิ่มผ่าน AddMethod)
    -- ห่อด้วย closure ของเราแทนการส่ง funcref ต่อดิบ ๆ เพื่อคุมอายุ reference
    -- และเปิดทางให้ override ข้างล่างแก้ signature ได้
    for name, f in pairs(F) do
        if Bridge.Callable(f) then
            fn[name] = function(...) return f(...) end
        end
    end

    ---------------------------------------------------------------
    -- เงิน: แปลงชื่อประเภทก่อนส่งเข้า hexa
    ---------------------------------------------------------------
    fn.AddMoney = function(moneytype, amount, reason)
        local mapped = mapMoneyType(moneytype)
        if not mapped then return false end
        return F.AddMoney(mapped, amount, reason) and true or false
    end

    fn.RemoveMoney = function(moneytype, amount, reason)
        local mapped = mapMoneyType(moneytype)
        if not mapped then return false end
        return F.RemoveMoney(mapped, amount, reason) and true or false
    end

    fn.SetMoney = function(moneytype, amount, reason)
        local mapped = mapMoneyType(moneytype)
        if not mapped then return false end
        return F.SetMoney(mapped, amount, reason) and true or false
    end

    fn.GetMoney = function(moneytype)
        local mapped = mapMoneyType(moneytype)
        if not mapped then return 0 end
        return F.GetMoney(mapped) or 0
    end

    ---------------------------------------------------------------
    -- ของในกระเป๋า
    ---------------------------------------------------------------
    -- ⚠️ จุดที่ต่างจาก rsg ตัวจริง: hexa_inventory:AddItem คืน (stored, dropped)
    -- dropped = true แปลว่ากระเป๋าเต็มจนต้องวางเป็นถุงไว้ที่พื้น — "ของถูกสร้าง
    -- ขึ้นจริงแล้ว" สคริปต์ rsg เช็คแค่ค่าเดียวแล้วคืนเงินถ้าได้ false ถ้าเราคืน
    -- false ตอน dropped ผู้เล่นจะได้ทั้งของที่พื้นและเงินคืน = ปั๊มของ
    -- จึงคืน true เมื่อ stored หรือ dropped และส่ง dropped เป็นค่าที่สองไว้ให้
    -- สคริปต์ที่รู้เรื่องใช้ต่อ
    --
    -- ⚠️ slot/info ต้องส่งเป็น false ไม่ใช่ nil: nil ที่อยู่ "กลาง" รายการ
    -- พารามิเตอร์จะถูกตัดทิ้งตอนข้าม resource boundary แล้ว reason จะเลื่อนไป
    -- นั่งตำแหน่ง slot แทน (ของจะถูกยัดลงช่องชื่อประหลาดที่มองไม่เห็นใน UI)
    fn.AddItem = function(item, amount, slot, info, reason)
        local stored, dropped = F.AddItem(
            item, amount, slot or false, info or false, reason or 'rsg-core:bridge')
        return (stored or dropped) and true or false, dropped and true or false
    end

    fn.RemoveItem = function(item, amount, slot, reason)
        return F.RemoveItem(item, amount, slot or false, reason or 'rsg-core:bridge') and true or false
    end

    -- เมธอดที่ rsg/qb มีบน Player แต่ hexa วางไว้ที่ hexa_inventory
    fn.ClearInventory = function(filterItems)
        if not inventoryReady() or not src then return false end
        return exports['hexa_inventory']:ClearInventory(src, filterItems)
    end

    fn.SetInventory = function(items)
        if not inventoryReady() or not src then return false end
        return exports['hexa_inventory']:SetInventory(src, items)
    end

    fn.GetSlotsByItem = function(items, itemName)
        if not inventoryReady() then return {} end
        return exports['hexa_inventory']:GetSlotsByItem(items or self.PlayerData.items, itemName) or {}
    end

    fn.GetFirstSlotByItem = function(items, itemName)
        if not inventoryReady() then return nil end
        return exports['hexa_inventory']:GetFirstSlotByItem(items or self.PlayerData.items, itemName)
    end

    ---------------------------------------------------------------
    -- แก๊ง — hexa ไม่มีระบบนี้ ทำให้เรียกได้โดยไม่พัง แต่ไม่ทำอะไรจริง
    ---------------------------------------------------------------
    fn.SetGang = function()
        warnOnce('gang', 'script called Player.Functions.SetGang but hexa_core has no gang system - returning false')
        return false
    end
    fn.SetGangDuty = fn.SetGang

    ---------------------------------------------------------------
    -- ชื่อเสียงประจำอาชีพ (qb: metadata.jobrep)
    ---------------------------------------------------------------
    fn.AddJobReputation = function(amount)
        amount = tonumber(amount)
        if not amount then return end
        local jobrep = self.PlayerData.metadata.jobrep or {}
        local jobName = self.PlayerData.job and self.PlayerData.job.name or 'unemployed'
        jobrep[jobName] = (tonumber(jobrep[jobName]) or 0) + amount
        F.SetMetaData('jobrep', jobrep)
    end

    ---------------------------------------------------------------
    -- ตัวผู้เล่นของ hexa แขวนเมธอดไว้ทั้งสองแบบ: แบบแบน Player.AddItem() และ
    -- แบบซ้อน Player.Functions.AddItem() (มิเรอร์ให้เองด้วย __newindex ใน
    -- hexa_core/server/player.lua) ตัวห่อนี้เคยมีแต่แบบซ้อน สคริปต์ที่เขียน
    -- แบบแบนจึงเจอ nil ทั้งที่ตัวจริงมีเมธอดนั้นอยู่ — ยกขึ้นมาให้ครบทั้งสองแบบ
    -- ต้องทำท้ายสุด หลัง override ด้านบนเขียน fn เสร็จแล้ว จะได้ยกตัวที่แปลง
    -- signature แล้วขึ้นมา ไม่ใช่ตัวดิบของ hexa
    ---------------------------------------------------------------
    for name, f in pairs(fn) do
        -- ห้ามทับ PlayerData / Offline / Functions ที่เป็นโครงของตัวห่อเอง
        if self[name] == nil then self[name] = f end
    end

    return self
end

RSGCore.Player.Wrap = wrapPlayer

-------------------------------------------------------------------
-- Config / Shared
-------------------------------------------------------------------
local function buildConfig()
    local core = Bridge.Core()
    local hc   = (core and core.Config) or {}
    local cfg  = Bridge.Shallow(hc)

    cfg.Money  = Bridge.Shallow(hc.Money)
    cfg.Player = Bridge.Shallow(hc.Player)

    -- qb/rsg อ่านสองช่องนี้ตรง ๆ ส่วน hexa เก็บไว้ใน PlayerDefaults
    local defaults = cfg.Player.PlayerDefaults or {}
    cfg.Player.MaxWeight   = cfg.Player.MaxWeight   or defaults.weight or 100
    cfg.Player.MaxInvSlots = cfg.Player.MaxInvSlots or defaults.slots  or 25

    -- ช่องที่ hexa ไม่มีเลย แต่สคริปต์ qb/rsg อ่านโดยไม่เช็ค nil
    cfg.Server = cfg.Server or {
        closed       = false,
        closedReason = 'Server Closed',
        uptime       = 0,
        whitelist    = false,
        discord      = '',
        permissions  = { 'admin', 'staff' },
    }

    return cfg
end

local function buildShared()
    local core = Bridge.Core()
    local hs   = (core and core.Shared) or {}
    local sh   = Bridge.Shallow(hs)

    sh.Items   = hs.Items   or {}
    sh.Jobs    = hs.Jobs    or {}
    sh.Weapons = hs.Weapons or {}

    -- ตารางที่ hexa ไม่มี — ใส่ตารางว่างกันสคริปต์ index ของ nil แล้วพัง
    sh.Gangs     = hs.Gangs     or {}
    sh.Vehicles  = hs.Vehicles  or {}
    sh.Locations = hs.Locations or {}

    return sh
end

-------------------------------------------------------------------
-- ตาราง Players
-------------------------------------------------------------------
local playersDirty, playersCache = true, {}

local function markPlayersDirty() playersDirty = true end

local function buildPlayers()
    if not playersDirty then return playersCache end
    playersDirty = false
    playersCache = {}

    local core = Bridge.Core()
    local F    = core and core.Functions
    if not F or not F.GetPlayers then return playersCache end

    local ok, list = pcall(F.GetPlayers)
    if not ok or type(list) ~= 'table' then return playersCache end

    for i = 1, #list do
        local wrapped = RSGCore.Functions.GetPlayer(list[i])
        if wrapped then playersCache[list[i]] = wrapped end
    end

    return playersCache
end

-------------------------------------------------------------------
-- RSGCore.Functions
-------------------------------------------------------------------
-- ยกทุกฟังก์ชันของ HexaCore.Functions มาแบบ late-bind ก่อน แล้วค่อยเขียนทับ
-- เฉพาะตัวที่ signature ไม่ตรงกันหรือคืน object ที่ต้องห่อ
local function mirrorFunctions()
    local core = Bridge.Core()
    local F    = core and core.Functions
    if type(F) ~= 'table' then return end

    for name, value in pairs(F) do
        if not overridden[name] and RSGCore.Functions[name] == nil and Bridge.Callable(value) then
            RSGCore.Functions[name] = Bridge.Fn(name)
        end
    end
end

local function override(name, fn)
    overridden[name] = true
    RSGCore.Functions[name] = fn
end

-- ---- ตัวดึงผู้เล่น (ต้องห่อผลลัพธ์ทุกตัว) ----
local function coreFn(name, ...)
    local core = Bridge.Core()
    local f    = core and core.Functions and core.Functions[name]
    if not f then return nil end
    local ok, result = pcall(f, ...)
    if not ok then return nil end
    return result
end

override('GetPlayer', function(source)
    return wrapPlayer(coreFn('GetPlayer', source))
end)

override('GetPlayerByCitizenId', function(citizenid)
    return wrapPlayer(coreFn('GetPlayerByCitizenId', citizenid))
end)

override('GetOfflinePlayerByCitizenId', function(citizenid)
    return wrapPlayer(coreFn('GetOfflinePlayerByCitizenId', citizenid))
end)

override('GetPlayerByLicense', function(license)
    return wrapPlayer(coreFn('GetPlayerByLicense', license))
end)

override('GetPlayerByAccount', function(account)
    return wrapPlayer(coreFn('GetPlayerByAccount', account))
end)

override('GetPlayerByCharInfo', function(property, value)
    return wrapPlayer(coreFn('GetPlayerByCharInfo', property, value))
end)

-- rsg เรียก GetRSGPlayers / qb เรียก GetQBPlayers — คืน map [source] = Player
override('GetRSGPlayers', buildPlayers)
override('GetQBPlayers', buildPlayers)
override('GetHexaPlayers', buildPlayers)

-- ---- แจ้งเตือน ----
-- rsg: Notify(source, text, type, length) | text เป็น string หรือ {text=, caption=}
override('Notify', function(source, text, ntype, length)
    local src = tonumber(source)
    local data = Bridge.NotifyData(text, ntype, length)

    if not src or src <= 0 then
        print(('[%s] Notify (console): %s'):format(RESOURCE, data.title))
        return
    end

    TriggerClientEvent('HexaCore:Notify', src, data)
end)

-- ---- สิทธิ์ ----
local function mapPermission(permission)
    if type(permission) == 'table' then
        local out = {}
        for i = 1, #permission do out[i] = mapPermission(permission[i]) end
        return out
    end
    if type(permission) ~= 'string' then return permission end
    return BridgeConfig.PermissionAliases[permission:lower()] or permission
end

override('AddPermission', function(source, permission)
    return coreFn('AddPermission', source, mapPermission(permission))
end)

override('RemovePermission', function(source, permission)
    return coreFn('RemovePermission', source, permission and mapPermission(permission) or nil)
end)

override('HasPermission', function(source, permission)
    return coreFn('HasPermission', source, mapPermission(permission)) and true or false
end)

-- ---- ของที่ hexa ไม่มีใน Functions ----
override('IsLicenseInUse', function(license)
    local core = Bridge.Core()
    local F    = core and core.Functions
    if not F or not F.GetPlayers then return false end

    local ok, list = pcall(F.GetPlayers)
    if not ok or type(list) ~= 'table' then return false end

    for i = 1, #list do
        local ids = GetPlayerIdentifiers(list[i])
        for j = 1, #ids do
            if ids[j] == license then return true end
        end
    end
    return false
end)

override('ExploitBan', function(playerId, origin)
    if GetResourceState('hexa_core') ~= 'started' then return end
    return exports['hexa_core']:ExploitBan(playerId, origin)
end)

-------------------------------------------------------------------
-- Callbacks (server side)
-------------------------------------------------------------------
-- ใช้ชื่อ event และลำดับพารามิเตอร์ชุดเดียวกับ rsg-core ตัวจริง
-- ต่างกันตรงคิว: rsg เก็บ callback ช่องเดียวต่อชื่อ ถ้ายิงชื่อเดิมซ้อนกัน
-- อันแรกจะหายเงียบ ๆ ตรงนี้เก็บเป็นคิวจึงซ้อนกันได้
local serverCallbacks = {}                 -- [name] = handler
local clientCallbackQueue = Bridge.NewQueue()

override('CreateCallback', function(name, cb)
    serverCallbacks[name] = cb
    RSGCore.ServerCallbacks[name] = cb
end)

override('TriggerCallback', function(name, source, cb, ...)
    local handler = serverCallbacks[name]
    if not handler then
        if BridgeConfig.Debug then
            print(('^3[%s]^7 server callback "%s" not found'):format(RESOURCE, tostring(name)))
        end
        return
    end
    handler(source, cb, ...)
end)

RegisterNetEvent('RSGCore:Server:TriggerCallback', function(name, ...)
    local src     = source
    local handler = serverCallbacks[name]

    -- ตอบกลับเสมอแม้ไม่มี handler ไม่งั้นฝั่ง client จะค้างรอตลอดกาล
    if not handler then
        return TriggerClientEvent('RSGCore:Client:TriggerCallback', src, name)
    end

    handler(src, function(...)
        TriggerClientEvent('RSGCore:Client:TriggerCallback', src, name, ...)
    end, ...)
end)

-- server -> client callback
override('TriggerClientCallback', function(name, source, cb, ...)
    clientCallbackQueue.push(name, cb, source)
    TriggerClientEvent('RSGCore:Client:TriggerClientCallback', source, name, ...)
end)

RegisterNetEvent('RSGCore:Server:TriggerClientCallback', function(name, ...)
    local src = source
    local cb  = clientCallbackQueue.pop(name, function(meta) return meta == src end)
    if not cb then return end
    cb(...)
end)

AddEventHandler('playerDropped', function()
    local src = source
    clientCallbackQueue.drop(function(meta) return meta == src end)
    markPlayersDirty()
end)

-------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------
function RSGCore.Commands.Add(name, help, arguments, argsrequired, callback, permission, ...)
    local core = Bridge.Core()
    local add  = core and core.Commands and core.Commands.Add
    if not add then
        print(('^1[%s]^7 cannot add command "%s" - HexaCore.Commands is not ready yet'):format(RESOURCE, tostring(name)))
        return
    end
    return add(name, help, arguments, argsrequired, callback, mapPermission(permission), ...)
end

function RSGCore.Commands.Refresh(source)
    local core    = Bridge.Core()
    local refresh = core and core.Commands and core.Commands.Refresh
    if refresh then return refresh(source) end
end

-------------------------------------------------------------------
-- ส่งต่อ event: HexaCore:* -> RSGCore:*
-------------------------------------------------------------------
-- สคริปต์ RSG ดักฟังชื่อฝั่ง RSGCore จึงต้องยิงชื่อนั้นตามให้ทุกครั้งที่ hexa ยิง
AddEventHandler('HexaCore:Server:PlayerLoaded', function(Player)
    markPlayersDirty()
    TriggerEvent('RSGCore:Server:PlayerLoaded', wrapPlayer(Player))
end)

AddEventHandler('HexaCore:Server:PlayerDropped', function(Player)
    markPlayersDirty()
    TriggerEvent('RSGCore:Server:PlayerDropped', wrapPlayer(Player))
end)

AddEventHandler('HexaCore:Server:OnPlayerUnload', function(src)
    markPlayersDirty()
    TriggerEvent('RSGCore:Server:OnPlayerUnload', src)
end)

-- HexaCore:Server:OnPlayerLoaded เป็น net event จาก client — source ของ event
-- เดิมถูกส่งต่อไปยัง handler ของ event ที่ยิงต่อภายในโดยอัตโนมัติ
-- แต่ยังส่ง src เป็นพารามิเตอร์แรกไว้ด้วย เผื่อสคริปต์ที่อ่านจากพารามิเตอร์
RegisterNetEvent('HexaCore:Server:OnPlayerLoaded', function()
    local src = source
    markPlayersDirty()
    TriggerEvent('RSGCore:Server:OnPlayerLoaded', src)
end)

AddEventHandler('HexaCore:Server:OnJobUpdate', function(src, job)
    markPlayersDirty()
    TriggerEvent('RSGCore:Server:OnJobUpdate', src, job)
end)

AddEventHandler('HexaCore:Server:OnMoneyChange', function(src, moneytype, amount, action, reason)
    markPlayersDirty()
    TriggerEvent('RSGCore:Server:OnMoneyChange', src, moneytype, amount, action, reason)
end)

AddEventHandler('HexaCore:Server:SetDuty', function(src, onduty)
    TriggerEvent('RSGCore:Server:SetDuty', src, onduty)
end)

AddEventHandler('HexaCore:Server:UpdateObject', function()
    mirrorFunctions()
    markPlayersDirty()
    TriggerEvent('RSGCore:Server:UpdateObject')
end)

AddEventHandler('HexaCore:Player:SetPlayerData', function(PlayerData)
    markPlayersDirty()
    TriggerEvent('RSGCore:Player:SetPlayerData', translatePlayerData(PlayerData))
end)

AddEventHandler('HexaCore:Server:PermissionsChanged', function(src)
    TriggerEvent('RSGCore:Server:PermissionsChanged', src)
end)

-------------------------------------------------------------------
-- ส่งต่อ event: RSGCore:* -> HexaCore:*
-------------------------------------------------------------------
-- net event ที่ client ของสคริปต์ RSG ยิงเข้ามาหา server
-- ⚠️ ชุดนี้เชื่อข้อมูลจาก client เท่าที่ rsg-core ตัวจริงเชื่อ (ไม่มากไปกว่านั้น)
-- ส่งต่อให้ hexa_core ตรวจ whitelist ให้ (เหมือน RSGCore:ToggleDuty ด้านล่าง)
-- ถ้าเรียก Player.Functions.SetMetaData เองที่นี่ = เปิดรูเดิมซ้ำอีกทาง client เขียนคีย์อะไรก็ได้
RegisterNetEvent('RSGCore:Server:SetMetaData', function(meta, data)
    TriggerEvent('HexaCore:Server:SetMetaData', meta, data)
end)

RegisterNetEvent('RSGCore:ToggleDuty', function()
    TriggerEvent('HexaCore:ToggleDuty')
end)

-- ส่งต่อให้ hexa_core เช่นกัน จะได้ใช้คูลดาวน์ต่อผู้เล่นตัวเดียวกัน (กันยิงรัวถล่ม MySQL)
RegisterNetEvent('RSGCore:UpdatePlayer', function()
    TriggerEvent('HexaCore:UpdatePlayer')
end)

RegisterNetEvent('RSGCore:CallCommand', function(command, args)
    local src  = source
    local core = Bridge.Core()
    local list = core and core.Commands and core.Commands.List
    if not list or not list[command] then return end

    local hasPerm = RSGCore.Functions.HasPermission(src, 'command.' .. list[command].name)
    if not hasPerm then
        return RSGCore.Functions.Notify(src, 'You do not have access to this command.', 'error')
    end
    list[command].callback(src, args)
end)

-- event ที่ rsg ประกาศว่า deprecated เพราะโดน exploit ได้ — รับไว้ให้ไม่ error
-- แต่ไม่ทำอะไรจริง เหมือนที่ hexa_core ทำกับชุดของตัวเอง
local function deprecated(eventName)
    RegisterNetEvent(eventName, function()
        print(('^3[%s]^7 %s was called by id %s - this event set is deprecated because it is exploitable, no effect')
            :format(RESOURCE, eventName, tostring(source)))
    end)
end

deprecated('RSGCore:Server:UseItem')
deprecated('RSGCore:Server:AddItem')
deprecated('RSGCore:Server:RemoveItem')

-------------------------------------------------------------------
-- ประกอบ object แล้วส่งออก
-------------------------------------------------------------------
mirrorFunctions()

-- ของที่อยู่ที่ราก HexaCore (ไม่ได้อยู่ใต้ .Functions)
local function rootFn(name)
    return function(...)
        local c = Bridge.Core()
        local f = c and c[name]
        if not Bridge.Callable(f) then return end
        return f(...)
    end
end

RSGCore.Debug       = rootFn('Debug')
RSGCore.ShowError   = rootFn('ShowError')
RSGCore.ShowSuccess = rootFn('ShowSuccess')

-- HexaCore.Player.* (Login / CheckPlayerData / Save / DeleteCharacter / CreateCitizenId ...)
-- ยกมาแบบ late-bind เหมือนกัน ยกเว้นตัวที่คืน Player object ซึ่งต้องห่อก่อน
local function mirrorPlayerNamespace()
    local core = Bridge.Core()
    local P    = core and core.Player
    if type(P) ~= 'table' then return end

    for name, value in pairs(P) do
        if RSGCore.Player[name] == nil and Bridge.Callable(value) then
            RSGCore.Player[name] = function(...)
                local c = Bridge.Core()
                local f = c and c.Player and c.Player[name]
                if not Bridge.Callable(f) then return end
                return f(...)
            end
        end
    end

    RSGCore.Player.GetOfflinePlayer = function(citizenid)
        local c = Bridge.Core()
        local f = c and c.Player and c.Player.GetOfflinePlayer
        if not Bridge.Callable(f) then return nil end
        return wrapPlayer(f(citizenid))
    end

    RSGCore.Player.GetPlayerByLicense = function(license)
        local c = Bridge.Core()
        local f = c and c.Player and c.Player.GetPlayerByLicense
        if not Bridge.Callable(f) then return nil end
        return wrapPlayer(f(license))
    end
end

mirrorPlayerNamespace()

local function buildCoreObject()
    mirrorFunctions()
    mirrorPlayerNamespace()

    RSGCore.Config  = buildConfig()
    RSGCore.Shared  = buildShared()
    RSGCore.Players = buildPlayers()

    local core = Bridge.Core()
    RSGCore.Commands.List        = (core and core.Commands and core.Commands.List) or {}
    RSGCore.Commands.Permissions = (core and core.Commands and core.Commands.Permissions) or { 'admin', 'staff' }
    RSGCore.UsableItems          = (core and core.UsableItems) or {}

    return RSGCore
end

exports('GetCoreObject', buildCoreObject)

CreateThread(function()
    Wait(1000)
    print(('^2[%s]^7 bridge ready - RSG scripts can call exports[\'rsg-core\']:GetCoreObject() as usual'):format(RESOURCE))
end)
