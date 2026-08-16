--[[
    hexa_mcp_bridge - authentication, IP allowlist and rate limiting

    Order of checks for every request:
        enabled -> key configured -> IP allowlist -> API key -> rate limit

    The key comparison is length-independent and accumulates the difference over
    every byte, so it does not short-circuit on the first mismatch.
]]

Hexa.Auth = {}

local Auth = Hexa.Auth
local Utils = Hexa.Utils

-- ---------------------------------------------------------------------------
-- Header access
-- ---------------------------------------------------------------------------

local API_KEY_HEADER = 'x-hexa-mcp-key'

--- FXServer does not normalise header casing, so look the name up case-insensitively.
---@param headers table
---@param name string lowercase header name
---@return string|nil
function Auth.GetHeader(headers, name)
    if type(headers) ~= 'table' then return nil end
    for key, value in pairs(headers) do
        if type(key) == 'string' and key:lower() == name then
            if type(value) == 'table' then
                return value[1]
            end
            return value
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Constant-time-ish key comparison
-- ---------------------------------------------------------------------------

--- Compares every byte regardless of where the first difference is.
--- Lua has no crypto primitives available here; this removes the obvious timing
--- signal, and the transport is loopback-only by default.
---@param a string
---@param b string
---@return boolean
function Auth.SecureEquals(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' then
        return false
    end

    local lengthA, lengthB = #a, #b
    local longest = lengthA > lengthB and lengthA or lengthB
    local difference = lengthA ~= lengthB and 1 or 0

    for index = 1, longest do
        local byteA = string.byte(a, index) or 0
        local byteB = string.byte(b, index) or 0
        if byteA ~= byteB then
            difference = difference + 1
        end
    end

    return difference == 0
end

-- ---------------------------------------------------------------------------
-- IP allowlist
-- ---------------------------------------------------------------------------

--- `req.address` arrives as "127.0.0.1:54321" or "[::1]:54321".
---@param address string|nil
---@return string
function Auth.NormaliseAddress(address)
    if type(address) ~= 'string' or address == '' then
        return ''
    end

    local bracketed = address:match('^%[(.-)%]')
    if bracketed then
        return bracketed:lower()
    end

    -- Only strip a trailing :port when there is exactly one colon (IPv4).
    local colons = select(2, address:gsub(':', ''))
    if colons == 1 then
        local host = address:match('^(.-):%d+$')
        if host then return host:lower() end
    end

    local mapped = address:match('^::ffff:(%d+%.%d+%.%d+%.%d+)')
    if mapped then return mapped end

    return address:lower()
end

---@param address string|nil
---@return boolean
function Auth.IsAddressAllowed(address)
    local list = Config.AllowedIPs
    if type(list) ~= 'table' or #list == 0 then
        return false
    end

    local host = Auth.NormaliseAddress(address)
    if host == '' then
        return false
    end

    for _, rule in ipairs(list) do
        if rule == '*' then
            return true
        end
        if Auth.NormaliseAddress(rule) == host then
            return true
        end
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Rate limiting (per IP, per tier)
-- ---------------------------------------------------------------------------

local buckets = {}

--- Token bucket. `tier` is 'read', 'write' or 'dangerous'.
---@param address string
---@param tier string
---@return boolean allowed
---@return number|nil retryAfterSeconds
function Auth.CheckRateLimit(address, tier)
    local capacity = Config.RateLimit and Config.RateLimit[tier] or 60
    local host = Auth.NormaliseAddress(address)
    local key = host .. '|' .. tier
    local now = GetGameTimer()

    local bucket = buckets[key]
    if not bucket then
        bucket = { tokens = capacity, last = now }
        buckets[key] = bucket
    end

    local elapsed = now - bucket.last
    if elapsed < 0 then elapsed = 0 end

    bucket.tokens = math.min(capacity, bucket.tokens + (elapsed / 60000.0) * capacity)
    bucket.last = now

    if bucket.tokens < 1 then
        local waitMs = ((1 - bucket.tokens) / capacity) * 60000.0
        return false, math.ceil(waitMs / 1000)
    end

    bucket.tokens = bucket.tokens - 1
    return true
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

--- Full authentication chain.
---@param req table FXServer request object
---@param tier string 'read' | 'write' | 'dangerous'
---@return boolean ok
---@return string|nil errorCode
---@return string|nil errorMessage
function Auth.Authenticate(req, tier)
    if not Config.Enabled then
        return false, 'SERVER_OFFLINE', 'hexa_mcp_bridge is disabled in config.lua'
    end

    if type(Config.ApiKey) ~= 'string' or #Config.ApiKey < 24 then
        return false, 'UNAUTHORIZED',
            'hexa_mcp_api_key convar is missing or shorter than 24 characters - the bridge refuses to run unauthenticated'
    end

    if not Auth.IsAddressAllowed(req.address) then
        return false, 'UNAUTHORIZED', 'client address is not in Config.AllowedIPs'
    end

    local provided = Auth.GetHeader(req.headers, API_KEY_HEADER)
    if not provided or not Auth.SecureEquals(provided, Config.ApiKey) then
        return false, 'UNAUTHORIZED', 'invalid or missing API key'
    end

    local allowed, retryAfter = Auth.CheckRateLimit(req.address, tier)
    if not allowed then
        return false, 'RATE_LIMITED', ('rate limit exceeded for %s operations, retry in %ds'):format(tier, retryAfter or 60)
    end

    return true
end

--- Warn loudly at startup if the bridge is unusable, rather than failing silently later.
CreateThread(function()
    Wait(2000)

    if not Config.Enabled then
        Utils.Log('warn', 'disabled via Config.Enabled - no endpoints will answer')
        return
    end

    if type(Config.ApiKey) ~= 'string' or Config.ApiKey == '' then
        Utils.Log('error', 'hexa_mcp_api_key convar is not set. Add: set hexa_mcp_api_key "<32+ char key>"')
    elseif #Config.ApiKey < 24 then
        Utils.Log('error', 'hexa_mcp_api_key is shorter than 24 characters - refusing to authenticate any request')
    else
        Utils.Log('info', ('ready - %d allowed address(es), console commands %s, server restart %s')
            :format(#Config.AllowedIPs,
                Config.AllowConsoleCommands and 'ENABLED' or 'disabled',
                Config.AllowServerRestart and 'ENABLED' or 'disabled'))
    end
end)
