--[[
    hexa_mcp_bridge - HTTP plumbing

    Response envelopes, request body handling, query parsing, audit logging and
    the server status snapshot. main.lua does the routing; this file gives it the
    primitives.
]]

Hexa.Bridge = {}

local Bridge = Hexa.Bridge
local Utils = Hexa.Utils

local BRIDGE_VERSION = '1.0.0'

-- ---------------------------------------------------------------------------
-- Responses
-- ---------------------------------------------------------------------------

local JSON_HEADERS = {
    ['Content-Type'] = 'application/json; charset=utf-8',
    ['Cache-Control'] = 'no-store',
    ['X-Content-Type-Options'] = 'nosniff',
}

--- HTTP status for each error code, so a client can react before parsing.
local STATUS_FOR_CODE = {
    UNAUTHORIZED = 401,
    FORBIDDEN = 403,
    INVALID_INPUT = 400,
    RESOURCE_NOT_FOUND = 404,
    PLAYER_NOT_FOUND = 404,
    COMMAND_NOT_ALLOWED = 403,
    RATE_LIMITED = 429,
    SERVER_OFFLINE = 503,
    NOT_IMPLEMENTED = 501,
    INTERNAL_ERROR = 500,
}

---@param res table
---@param data any
function Bridge.Success(res, data)
    res.writeHead(200, JSON_HEADERS)
    res.send(json.encode({ success = true, data = data or {} }))
end

---@param res table
---@param code string
---@param message string
function Bridge.Error(res, code, message)
    local status = STATUS_FOR_CODE[code] or 500
    res.writeHead(status, JSON_HEADERS)
    res.send(json.encode({
        success = false,
        error = { code = code, message = message },
    }))
end

-- ---------------------------------------------------------------------------
-- Request parsing
-- ---------------------------------------------------------------------------

--- Split "/resource/action?name=x" into path and decoded query table.
---@param rawPath string
---@return string path
---@return table query
function Bridge.ParsePath(rawPath)
    if type(rawPath) ~= 'string' or rawPath == '' then
        return '/', {}
    end

    local path, queryString = rawPath:match('^([^?]*)%??(.*)$')
    path = path or '/'

    -- Normalise: strip a trailing slash, collapse an empty path to root.
    if #path > 1 then
        path = path:gsub('/+$', '')
    end
    if path == '' then
        path = '/'
    end

    local query = {}
    if queryString and queryString ~= '' then
        for key, value in queryString:gmatch('([^&=?]+)=?([^&]*)') do
            local decodedKey = key:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
            local decodedValue = value:gsub('+', ' '):gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
            query[decodedKey] = decodedValue
        end
    end

    return path, query
end

--- Read and JSON-decode the request body, enforcing the size cap.
---@param req table
---@param callback function(body: table|nil, errorMessage: string|nil)
function Bridge.ReadBody(req, callback)
    local settled = false

    req.setDataHandler(function(raw)
        if settled then return end
        settled = true

        if type(raw) ~= 'string' or raw == '' then
            callback({})
            return
        end

        if #raw > (Config.MaxRequestBytes or 16384) then
            callback(nil, ('request body exceeds %d bytes'):format(Config.MaxRequestBytes or 16384))
            return
        end

        local ok, decoded = pcall(json.decode, raw)
        if not ok or type(decoded) ~= 'table' then
            callback(nil, 'request body is not a JSON object')
            return
        end

        callback(decoded)
    end)
end

-- ---------------------------------------------------------------------------
-- Audit
-- ---------------------------------------------------------------------------

--- One structured line per state-changing request.
--- txAdmin captures the console, so this ends up in fxserver.log automatically.
--- Never log the API key, headers or any credential.
---@param entry table
function Bridge.Audit(entry)
    if not Config.AuditToConsole then return end

    local payload = {
        timestamp = Utils.Timestamp(),
        service = 'hexa_mcp_bridge',
        endpoint = entry.endpoint,
        action = entry.action,
        client = entry.client or 'mcp',
        success = entry.success and true or false,
    }

    if entry.resource then payload.resource = entry.resource end
    if entry.playerId then payload.playerId = entry.playerId end
    if entry.command then payload.command = entry.command end
    if entry.reason then payload.reason = entry.reason end
    if entry.errorCode then payload.errorCode = entry.errorCode end

    print(('^5[hexa_mcp_bridge] AUDIT^7 %s'):format(json.encode(payload)))
end

-- ---------------------------------------------------------------------------
-- Status snapshot
-- ---------------------------------------------------------------------------

--- Detect the roleplay framework from the started resources.
---@return string
local function detectFramework()
    if Config.Framework and Config.Framework ~= 'auto' then
        return Config.Framework
    end

    local candidates = {
        { resource = 'hexa_core', id = 'hexacore' },
        { resource = 'vorp_core', id = 'vorp' },
        { resource = 'rsg-core',  id = 'rsgcore' },
    }

    for _, candidate in ipairs(candidates) do
        if GetResourceState(candidate.resource) == 'started' then
            return candidate.id
        end
    end

    return 'standalone'
end

--- Seconds since the server process started. Server-side GetGameTimer() counts
--- milliseconds from server start.
---@return number
function Bridge.Uptime()
    return math.floor(GetGameTimer() / 1000)
end

--- The payload behind /status.
---@return table
function Bridge.Status()
    local counts = Hexa.Resources.Counts()
    local _, playerCount = Hexa.Players.List()

    return {
        online = true,
        uptime = Bridge.Uptime(),
        players = playerCount,
        maxPlayers = Hexa.Players.MaxPlayers(),
        resources = counts,
        server = {
            hostname = GetConvar('sv_hostname', 'unknown'),
            gameName = GetConvar('gamename', 'rdr3'),
            framework = detectFramework(),
            onesync = GetConvar('onesync', 'off'),
            build = GetConvar('sv_enforceGameBuild', ''),
        },
        bridge = {
            version = BRIDGE_VERSION,
            resource = GetCurrentResourceName(),
        },
    }
end

--- Lightweight liveness probe. `tickMs` is measured by yielding one frame, so a
--- blocked main thread shows up as a large value or a timeout.
---@param callback function(result: table)
function Bridge.Heartbeat(callback)
    local startedAt = GetGameTimer()

    CreateThread(function()
        Wait(0)
        callback({
            time = os.time(),
            uptime = Bridge.Uptime(),
            tickMs = GetGameTimer() - startedAt,
        })
    end)
end

-- ---------------------------------------------------------------------------
-- Server restart
-- ---------------------------------------------------------------------------

local restartScheduled = false

--- Schedule a graceful shutdown after a grace period.
---
--- FXServer has no "restart myself" primitive: the documented way to cycle the
--- server is to let it exit and have the supervisor (txAdmin) start it again.
--- That is what happens here. `quit` is deliberately NOT exposed through the
--- console command allowlist - this is the only path that can reach it, and it
--- is gated by Config.AllowServerRestart plus the MCP permission matrix.
---@param delaySeconds number
---@param reason string
---@return table|nil result
---@return string|nil errorCode
---@return string|nil errorMessage
function Bridge.ScheduleRestart(delaySeconds, reason)
    if not Config.AllowServerRestart then
        return nil, 'FORBIDDEN', 'server restart is disabled in config.lua (Config.AllowServerRestart)'
    end

    if restartScheduled then
        return nil, 'FORBIDDEN', 'a restart is already scheduled - refusing to schedule a second one'
    end

    restartScheduled = true

    CreateThread(function()
        local remaining = delaySeconds

        while remaining > 0 do
            if remaining == delaySeconds or remaining == 60 or remaining == 30 or remaining == 10 or remaining <= 5 then
                Utils.Log('warn', ('server restart in %ds - %s'):format(remaining, reason))
                TriggerClientEvent('chat:addMessage', -1, {
                    color = { 255, 120, 0 },
                    args = { 'SERVER', ('Restarting in %d seconds: %s'):format(remaining, reason) },
                })
            end
            Wait(1000)
            remaining = remaining - 1
        end

        Utils.Log('warn', ('restarting now - %s'):format(reason))
        ExecuteCommand(('quit "hexa_mcp: %s"'):format(reason))
    end)

    return {
        scheduled = true,
        delaySeconds = delaySeconds,
        reason = reason,
    }
end
