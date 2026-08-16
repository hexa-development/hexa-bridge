--[[
    hexa_mcp_bridge - player inspection and kick

    Identifiers are personal data. This file is the only place that ever sees the
    raw values, and it applies Config.PlayerIdentifiers / Config.PlayerEndpoint
    before anything leaves the game server. The MCP side cannot ask for more than
    the policy set here.
]]

Hexa.Players = {}

local Players = Hexa.Players
local Utils = Hexa.Utils

-- ---------------------------------------------------------------------------
-- Disclosure
-- ---------------------------------------------------------------------------

--- Is this identifier type suppressed entirely?
---@param identifier string
---@return boolean
local function isHidden(identifier)
    local prefix = identifier:match('^(%w+):')
    if not prefix then return true end
    return Utils.InList(Config.HiddenIdentifierTypes, prefix, true)
end

--- Apply the disclosure policy to a player's identifier list.
---@param source number
---@return table
local function disclosedIdentifiers(source)
    local mode = Config.PlayerIdentifiers or 'masked'
    if mode == 'none' then
        return {}
    end

    local out = {}
    local raw = GetPlayerIdentifiers(source)
    if type(raw) ~= 'table' then
        return out
    end

    for _, identifier in ipairs(raw) do
        if type(identifier) == 'string' and not isHidden(identifier) then
            if mode == 'full' then
                out[#out + 1] = identifier
            else
                out[#out + 1] = Utils.MaskIdentifier(identifier)
            end
        end
    end

    return out
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

--- Build the wire representation of one connected player.
---@param source number
---@return table|nil
function Players.Describe(source)
    local name = GetPlayerName(source)
    if not name then
        return nil
    end

    local ping = GetPlayerPing(source)
    local lastMsg = GetPlayerLastMsg(source)

    return {
        id = tonumber(source),
        name = name,
        ping = type(ping) == 'number' and ping or 0,
        identifiers = disclosedIdentifiers(source),
        endpoint = Config.PlayerEndpoint and GetPlayerEndpoint(source) or nil,
        lastMsgMs = type(lastMsg) == 'number' and lastMsg or nil,
    }
end

--- Every connected player.
---@return table players
---@return number count
function Players.List()
    local out = {}
    for _, source in ipairs(GetPlayers()) do
        local player = Players.Describe(source)
        if player then
            out[#out + 1] = player
        end
    end

    table.sort(out, function(a, b) return a.id < b.id end)
    return out, #out
end

--- One player by server id, or nil.
---@param id number
---@return table|nil
function Players.Get(id)
    for _, source in ipairs(GetPlayers()) do
        if tonumber(source) == id then
            return Players.Describe(source)
        end
    end
    return nil
end

--- sv_maxclients, with a sane fallback.
---@return number
function Players.MaxPlayers()
    local configured = GetConvarInt('sv_maxclients', 32)
    if type(configured) ~= 'number' or configured <= 0 then
        return 32
    end
    return configured
end

-- ---------------------------------------------------------------------------
-- Kick
-- ---------------------------------------------------------------------------

--- Disconnect a player with a reason they will see.
---@param id number
---@param reason string already sanitised
---@return table|nil result
---@return string|nil errorCode
---@return string|nil errorMessage
function Players.Kick(id, reason)
    if not Config.AllowPlayerKick then
        return nil, 'FORBIDDEN', 'player kick is disabled in config.lua (Config.AllowPlayerKick)'
    end

    local player = Players.Get(id)
    if not player then
        return nil, 'PLAYER_NOT_FOUND', ('no connected player with server id %d'):format(id)
    end

    DropPlayer(tostring(id), ('[hexa_mcp] %s'):format(reason))

    return {
        id = id,
        name = player.name,
        kicked = true,
    }
end
