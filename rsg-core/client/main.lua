--[[
    rsg-core (compat bridge) — ฝั่ง client
    ---------------------------------------------------------------------
        local RSGCore = exports['rsg-core']:GetCoreObject()
        RSGCore.Functions.Notify('ข้อความ', 'success', 5000)
        RSGCore.Functions.TriggerCallback('ชื่อ', function(result) end, ...)
]]

local RESOURCE = GetCurrentResourceName()

RSGCore = {
    PlayerData      = {},
    Config          = {},
    Shared          = {},
    Functions       = {},
    ServerCallbacks = {},
    ClientCallbacks = {},
}

local overridden = {}

-------------------------------------------------------------------
-- PlayerData
-------------------------------------------------------------------
-- hexa ยิง HexaCore:Player:SetPlayerData ทุกครั้งที่ข้อมูลเปลี่ยน
-- เก็บสำเนาล่าสุดไว้ที่นี่ แล้วส่งต่อในชื่อของ RSGCore ให้สคริปต์ที่ดักฟัง
local function translatePlayerData(pd)
    if type(pd) ~= 'table' then return {} end

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

local function pullPlayerData()
    local core = Bridge.Core()
    RSGCore.PlayerData = translatePlayerData(core and core.PlayerData)
    return RSGCore.PlayerData
end

pullPlayerData()

-------------------------------------------------------------------
-- Config / Shared
-------------------------------------------------------------------
local function buildConfig()
    local core = Bridge.Core()
    local hc   = (core and core.Config) or {}
    local cfg  = Bridge.Shallow(hc)

    cfg.Money  = Bridge.Shallow(hc.Money)
    cfg.Player = Bridge.Shallow(hc.Player)

    local defaults = cfg.Player.PlayerDefaults or {}
    cfg.Player.MaxWeight   = cfg.Player.MaxWeight   or defaults.weight or 100
    cfg.Player.MaxInvSlots = cfg.Player.MaxInvSlots or defaults.slots  or 25

    return cfg
end

local function buildShared()
    local core = Bridge.Core()
    local hs   = (core and core.Shared) or {}
    local sh   = Bridge.Shallow(hs)

    sh.Items   = hs.Items   or {}
    sh.Jobs    = hs.Jobs    or {}
    sh.Weapons = hs.Weapons or {}

    sh.Gangs     = hs.Gangs     or {}
    sh.Vehicles  = hs.Vehicles  or {}
    sh.Locations = hs.Locations or {}

    return sh
end

-------------------------------------------------------------------
-- RSGCore.Functions
-------------------------------------------------------------------
-- ฝั่ง client ฟังก์ชันของ hexa กับ rsg เป็นชุดเดียวกันเกือบทั้งหมด
-- (สายเดียวกันมาจาก qb-core) จึงยกมาแบบ late-bind ทั้งก้อนแล้วเขียนทับเฉพาะ
-- ตัวที่ signature ต่างกันจริง ๆ
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

-- rsg: Notify(text, type, length) — hexa รับเป็นตาราง
override('Notify', function(text, ntype, length)
    TriggerEvent('HexaCore:Notify', Bridge.NotifyData(text, ntype, length))
end)

override('GetPlayerData', function(cb)
    local data = pullPlayerData()
    if not cb then return data end
    cb(data)
end)

-------------------------------------------------------------------
-- Callbacks
-------------------------------------------------------------------
local serverCallbackQueue = Bridge.NewQueue()   -- client -> server
local clientCallbacks     = {}                  -- server -> client

override('TriggerCallback', function(name, cb, ...)
    serverCallbackQueue.push(name, cb)
    RSGCore.ServerCallbacks[name] = cb
    TriggerServerEvent('RSGCore:Server:TriggerCallback', name, ...)
end)

RegisterNetEvent('RSGCore:Client:TriggerCallback', function(name, ...)
    local cb = serverCallbackQueue.pop(name)
    if not cb then return end
    RSGCore.ServerCallbacks[name] = nil
    cb(...)
end)

override('CreateClientCallback', function(name, cb)
    clientCallbacks[name] = cb
    RSGCore.ClientCallbacks[name] = cb
end)

override('TriggerClientCallback', function(name, cb, ...)
    local handler = clientCallbacks[name]
    if not handler then return end
    handler(cb, ...)
end)

RegisterNetEvent('RSGCore:Client:TriggerClientCallback', function(name, ...)
    local handler = clientCallbacks[name]
    if not handler then
        -- ตอบกลับว่าง ไม่งั้นฝั่ง server ค้างคิวไว้ตลอด
        return TriggerServerEvent('RSGCore:Server:TriggerClientCallback', name)
    end

    handler(function(...)
        TriggerServerEvent('RSGCore:Server:TriggerClientCallback', name, ...)
    end, ...)
end)

-------------------------------------------------------------------
-- ส่งต่อ event: HexaCore:* -> RSGCore:*
-------------------------------------------------------------------
-- hexa ยิงตัวนี้แบบ local จาก client/spawn.lua — RegisterNetEvent ลงทะเบียน
-- handler ให้ทั้งทาง local และทางเน็ต จึงครอบทั้งสองทางด้วยตัวเดียว
RegisterNetEvent('HexaCore:Client:OnPlayerLoaded', function()
    pullPlayerData()
    TriggerEvent('RSGCore:Client:OnPlayerLoaded')
end)

RegisterNetEvent('HexaCore:Client:OnPlayerUnload', function()
    RSGCore.PlayerData = {}
    TriggerEvent('RSGCore:Client:OnPlayerUnload')
end)

RegisterNetEvent('HexaCore:Player:SetPlayerData', function(val)
    RSGCore.PlayerData = translatePlayerData(val)
    TriggerEvent('RSGCore:Player:SetPlayerData', RSGCore.PlayerData)
end)

RegisterNetEvent('HexaCore:Client:OnJobUpdate', function(job)
    TriggerEvent('RSGCore:Client:OnJobUpdate', job)
end)

RegisterNetEvent('HexaCore:Client:OnMoneyChange', function(moneytype, amount, action, reason)
    TriggerEvent('RSGCore:Client:OnMoneyChange', moneytype, amount, action, reason)
end)

RegisterNetEvent('HexaCore:Client:SetDuty', function(onduty)
    TriggerEvent('RSGCore:Client:SetDuty', onduty)
end)

AddEventHandler('HexaCore:Client:UpdateObject', function()
    mirrorFunctions()
    pullPlayerData()
    TriggerEvent('RSGCore:Client:UpdateObject')
end)

RegisterNetEvent('HexaCore:Client:OnSharedUpdate', function(tableName, key, value)
    TriggerEvent('RSGCore:Client:OnSharedUpdate', tableName, key, value)
end)

RegisterNetEvent('HexaCore:Client:OnSharedUpdateMultiple', function(tableName, values)
    TriggerEvent('RSGCore:Client:OnSharedUpdateMultiple', tableName, values)
end)

-------------------------------------------------------------------
-- ส่งต่อ event: RSGCore:* -> hexa
-------------------------------------------------------------------
-- สคริปต์ RSG ฝั่ง server ยิง TriggerClientEvent('RSGCore:Notify', src, ...)
RegisterNetEvent('RSGCore:Notify', function(text, ntype, length)
    TriggerEvent('HexaCore:Notify', Bridge.NotifyData(text, ntype, length))
end)

-- ลงทะเบียนชื่อ event ฝั่ง client ที่สคริปต์ RSG ยิงมาจาก server ไว้ล่วงหน้า
-- ถ้าไม่มี resource ไหน RegisterNetEvent ชื่อนั้นเลย เซิร์ฟจะทิ้ง event ทิ้งเงียบ ๆ
-- (handler ว่างตรงนี้ทำหน้าที่ "เปิดชื่อ" ให้ AddEventHandler ของ resource อื่นได้ยิน)
local passiveEvents = {
    'RSGCore:Client:OnPlayerLoaded',
    'RSGCore:Client:OnPlayerUnload',
    'RSGCore:Client:OnJobUpdate',
    'RSGCore:Client:OnMoneyChange',
    'RSGCore:Client:SetDuty',
    'RSGCore:Client:UpdateObject',
    'RSGCore:Player:SetPlayerData',
    'RSGCore:Client:OnSharedUpdate',
    'RSGCore:Client:OnSharedUpdateMultiple',
}

for i = 1, #passiveEvents do
    RegisterNetEvent(passiveEvents[i])
end

RegisterNetEvent('RSGCore:Command:TeleportToPlayer', function(coords)
    TriggerEvent('HexaCore:Command:TeleportToPlayer', coords)
end)

RegisterNetEvent('RSGCore:Command:TeleportToCoords', function(x, y, z, h)
    TriggerEvent('HexaCore:Command:TeleportToCoords', x, y, z, h)
end)

RegisterNetEvent('RSGCore:Command:SpawnVehicle', function(model)
    TriggerEvent('HexaCore:Command:SpawnVehicle', model)
end)

RegisterNetEvent('RSGCore:Command:DeleteVehicle', function()
    TriggerEvent('HexaCore:Command:DeleteVehicle')
end)

-------------------------------------------------------------------
-- ประกอบ object แล้วส่งออก
-------------------------------------------------------------------
mirrorFunctions()

RSGCore.Debug = function(...)
    local c = Bridge.Core()
    if c and Bridge.Callable(c.Debug) then return c.Debug(...) end
end

exports('GetCoreObject', function()
    mirrorFunctions()

    RSGCore.Config = buildConfig()
    RSGCore.Shared = buildShared()
    pullPlayerData()

    return RSGCore
end)
