--[[
    hexa_mcp_bridge - HTTP router

    FXServer mounts a resource's HTTP handler at  http://<host>:<port>/<resource>
    so with this resource named hexa_mcp_bridge the base URL is:

        http://127.0.0.1:30120/hexa_mcp_bridge

    and the routes below hang off it (/status, /players, ...).

    Every request runs the same chain:

        authenticate -> validate -> check permission -> execute -> audit -> respond

    Handlers must call respond() exactly once on every path, including errors.
]]

local Utils = Hexa.Utils
local Auth = Hexa.Auth
local Bridge = Hexa.Bridge
local Resources = Hexa.Resources
local Players = Hexa.Players
local Console = Hexa.Console

-- ---------------------------------------------------------------------------
-- Route table
-- ---------------------------------------------------------------------------

-- tier drives rate limiting and audit verbosity.
-- handler(ctx) where ctx = { req, res, query, body, address, ok, fail }
local routes = {}

---@param method string
---@param path string
---@param tier string 'read' | 'write' | 'dangerous'
---@param handler function
local function route(method, path, tier, handler)
    routes[method .. ' ' .. path] = { tier = tier, handler = handler, path = path, method = method }
end

-- ---------------------------------------------------------------------------
-- Read endpoints
-- ---------------------------------------------------------------------------

route('GET', '/health', 'read', function(ctx)
    ctx.ok({
        alive = true,
        resource = GetCurrentResourceName(),
        uptime = Bridge.Uptime(),
    })
end)

route('GET', '/status', 'read', function(ctx)
    if not Config.AllowReadStatus then
        return ctx.fail('FORBIDDEN', 'status reads are disabled in config.lua')
    end
    ctx.ok(Bridge.Status())
end)

route('GET', '/heartbeat', 'read', function(ctx)
    if not Config.AllowReadStatus then
        return ctx.fail('FORBIDDEN', 'status reads are disabled in config.lua')
    end
    Bridge.Heartbeat(function(result)
        ctx.ok(result)
    end)
end)

route('GET', '/resources', 'read', function(ctx)
    if not Config.AllowReadResources then
        return ctx.fail('FORBIDDEN', 'resource reads are disabled in config.lua')
    end

    local filterState = ctx.query.state
    if filterState and not filterState:match('^%a+$') then
        return ctx.fail('INVALID_INPUT', 'state filter must be a single word')
    end

    local list, summary = Resources.List(filterState)
    ctx.ok({ resources = list, summary = summary, count = #list })
end)

route('GET', '/resource', 'read', function(ctx)
    if not Config.AllowReadResources then
        return ctx.fail('FORBIDDEN', 'resource reads are disabled in config.lua')
    end

    local name = ctx.query.name
    local valid, reason = Utils.IsValidResourceName(name)
    if not valid then
        return ctx.fail('INVALID_INPUT', reason)
    end

    if not Resources.Exists(name) then
        return ctx.fail('RESOURCE_NOT_FOUND', ('resource "%s" does not exist on this server'):format(name))
    end

    ctx.ok(Resources.Describe(name))
end)

route('GET', '/players', 'read', function(ctx)
    if not Config.AllowReadPlayers then
        return ctx.fail('FORBIDDEN', 'player reads are disabled in config.lua')
    end

    local list, count = Players.List()
    ctx.ok({ players = list, count = count, maxPlayers = Players.MaxPlayers() })
end)

route('GET', '/player', 'read', function(ctx)
    if not Config.AllowReadPlayers then
        return ctx.fail('FORBIDDEN', 'player reads are disabled in config.lua')
    end

    local id = Utils.ToBoundedInt(ctx.query.id, 1, 65535)
    if not id then
        return ctx.fail('INVALID_INPUT', 'id must be an integer between 1 and 65535')
    end

    local player = Players.Get(id)
    if not player then
        return ctx.fail('PLAYER_NOT_FOUND', ('no connected player with server id %d'):format(id))
    end

    ctx.ok(player)
end)

route('GET', '/console', 'read', function(ctx)
    if not Config.AllowReadConsole then
        return ctx.fail('FORBIDDEN', 'console reads are disabled in config.lua')
    end

    local lines = Utils.ToBoundedInt(ctx.query.lines, 1, Config.MaxLogLines or 1000) or 100
    local filter = ctx.query.filter and Utils.SanitiseText(ctx.query.filter, 64) or nil
    local level = ctx.query.level

    if level and level ~= 'info' and level ~= 'warn' and level ~= 'error' then
        return ctx.fail('INVALID_INPUT', 'level must be info, warn or error')
    end

    ctx.ok(Console.GetLines(lines, filter, level))
end)

route('GET', '/errors', 'read', function(ctx)
    if not Config.AllowReadConsole then
        return ctx.fail('FORBIDDEN', 'console reads are disabled in config.lua')
    end

    local limit = Utils.ToBoundedInt(ctx.query.limit, 1, Config.MaxLogLines or 1000) or 100
    local resource = ctx.query.resource

    if resource then
        local valid, reason = Utils.IsValidResourceName(resource)
        if not valid then
            return ctx.fail('INVALID_INPUT', reason)
        end
    end

    ctx.ok({ errors = Console.GetErrors(limit, resource) })
end)

-- ---------------------------------------------------------------------------
-- Write endpoints
-- ---------------------------------------------------------------------------

local VALID_ACTIONS = { start = true, stop = true, restart = true, ensure = true }

route('POST', '/resource/action', 'write', function(ctx)
    local action = ctx.body.action
    local resource = ctx.body.resource

    if type(action) ~= 'string' or not VALID_ACTIONS[action] then
        return ctx.fail('INVALID_INPUT', 'action must be one of start, stop, restart, ensure')
    end

    local valid, reason = Utils.IsValidResourceName(resource)
    if not valid then
        return ctx.fail('INVALID_INPUT', reason)
    end

    -- Perform() blocks while waiting for the state to settle, so run it in a thread.
    CreateThread(function()
        local result, code, message = Resources.Perform(action, resource)

        Bridge.Audit({
            endpoint = '/resource/action',
            action = action,
            resource = resource,
            success = result ~= nil and result.verified or false,
            errorCode = code,
        })

        if not result then
            return ctx.fail(code or 'INTERNAL_ERROR', message or 'resource action failed')
        end
        ctx.ok(result)
    end)
end)

route('POST', '/player/kick', 'write', function(ctx)
    local id = Utils.ToBoundedInt(ctx.body.id, 1, 65535)
    if not id then
        return ctx.fail('INVALID_INPUT', 'id must be an integer between 1 and 65535')
    end

    local reason = Utils.SanitiseText(ctx.body.reason, 200)
    if not reason then
        return ctx.fail('INVALID_INPUT', 'reason is required')
    end

    local result, code, message = Players.Kick(id, reason)

    Bridge.Audit({
        endpoint = '/player/kick',
        action = 'kick_player',
        playerId = id,
        reason = reason,
        success = result ~= nil,
        errorCode = code,
    })

    if not result then
        return ctx.fail(code or 'INTERNAL_ERROR', message or 'kick failed')
    end
    ctx.ok(result)
end)

-- ---------------------------------------------------------------------------
-- Dangerous endpoints
-- ---------------------------------------------------------------------------

route('POST', '/console/execute', 'dangerous', function(ctx)
    local command = ctx.body.command
    local valid, reason = Utils.IsValidCommandWord(command)
    if not valid then
        return ctx.fail('INVALID_INPUT', reason)
    end

    local allowed, why = Console.IsCommandAllowed(command)
    if not allowed then
        Bridge.Audit({
            endpoint = '/console/execute',
            action = 'execute_console_command',
            command = command,
            success = false,
            errorCode = 'COMMAND_NOT_ALLOWED',
        })
        return ctx.fail('COMMAND_NOT_ALLOWED', why)
    end

    local args = {}
    if ctx.body.args ~= nil then
        if type(ctx.body.args) ~= 'table' then
            return ctx.fail('INVALID_INPUT', 'args must be an array of strings')
        end
        if #ctx.body.args > 8 then
            return ctx.fail('INVALID_INPUT', 'at most 8 arguments are allowed')
        end
        for index, arg in ipairs(ctx.body.args) do
            local okArg, argReason = Utils.IsValidCommandArg(arg)
            if not okArg then
                return ctx.fail('INVALID_INPUT', ('argument %d: %s'):format(index, argReason))
            end
            args[#args + 1] = arg
        end
    end

    -- An allowlisted verb that controls a resource must still respect the
    -- protected-resource list, otherwise `stop hexa_mcp_bridge` would work.
    local lowered = command:lower()
    if (lowered == 'stop' or lowered == 'restart' or lowered == 'ensure' or lowered == 'start') and args[1] then
        if Resources.IsProtected(args[1]) then
            return ctx.fail('FORBIDDEN', ('resource "%s" is protected and cannot be controlled through hexa_mcp'):format(args[1]))
        end
    end

    Console.Execute(command, args, function(output)
        Bridge.Audit({
            endpoint = '/console/execute',
            action = 'execute_console_command',
            command = table.concat({ command, table.unpack(args) }, ' '),
            success = true,
        })
        ctx.ok({ command = command, executed = true, output = output })
    end)
end)

route('POST', '/server/restart', 'dangerous', function(ctx)
    local delaySeconds = Utils.ToBoundedInt(ctx.body.delaySeconds, 0, 300)
    if delaySeconds == nil then
        delaySeconds = 30
    end

    local reason = Utils.SanitiseText(ctx.body.reason, 200) or 'requested through hexa_mcp'

    local result, code, message = Bridge.ScheduleRestart(delaySeconds, reason)

    Bridge.Audit({
        endpoint = '/server/restart',
        action = 'restart_server',
        reason = reason,
        success = result ~= nil,
        errorCode = code,
    })

    if not result then
        return ctx.fail(code or 'INTERNAL_ERROR', message or 'restart could not be scheduled')
    end
    ctx.ok(result)
end)

-- ---------------------------------------------------------------------------
-- Dispatcher
-- ---------------------------------------------------------------------------

--- Build the per-request context with single-use response helpers.
---@param req table
---@param res table
---@param query table
---@param body table
---@return table
local function makeContext(req, res, query, body)
    local answered = false

    local ctx = {
        req = req,
        res = res,
        query = query,
        body = body,
        address = req.address,
    }

    ctx.ok = function(data)
        if answered then return end
        answered = true
        Bridge.Success(res, data)
    end

    ctx.fail = function(code, message)
        if answered then return end
        answered = true
        Bridge.Error(res, code, message)
    end

    return ctx
end

---@param req table
---@param res table
---@param body table
local function dispatch(req, res, body)
    local path, query = Bridge.ParsePath(req.path)
    local method = (req.method or 'GET'):upper()
    local entry = routes[method .. ' ' .. path]

    if not entry then
        return Bridge.Error(res, 'RESOURCE_NOT_FOUND', ('no route for %s %s'):format(method, path))
    end

    local ok, code, message = Auth.Authenticate(req, entry.tier)
    if not ok then
        -- Do not reveal which check failed beyond the code itself.
        Utils.Log('warn', ('rejected %s %s from %s: %s'):format(method, path, tostring(req.address), code or 'UNAUTHORIZED'))
        return Bridge.Error(res, code or 'UNAUTHORIZED', message or 'unauthorized')
    end

    if Config.AuditReads and entry.tier == 'read' then
        Bridge.Audit({ endpoint = path, action = method, success = true })
    end

    local ctx = makeContext(req, res, query, body)

    local handled, err = pcall(entry.handler, ctx)
    if not handled then
        -- Never send an internal error message or traceback to the client.
        Utils.Log('error', ('handler error on %s %s: %s'):format(method, path, tostring(err)))
        ctx.fail('INTERNAL_ERROR', 'internal error')
    end
end

SetHttpHandler(function(req, res)
    -- One safety net around everything: an unhandled error here would leave the
    -- MCP server waiting until its timeout.
    local ok, err = pcall(function()
        local method = (req.method or 'GET'):upper()

        if method ~= 'GET' and method ~= 'POST' then
            return Bridge.Error(res, 'INVALID_INPUT', 'only GET and POST are supported')
        end

        if method == 'GET' then
            dispatch(req, res, {})
            return
        end

        Bridge.ReadBody(req, function(body, bodyError)
            if not body then
                return Bridge.Error(res, 'INVALID_INPUT', bodyError or 'invalid request body')
            end
            dispatch(req, res, body)
        end)
    end)

    if not ok then
        Utils.Log('error', ('http handler error: %s'):format(tostring(err)))
        pcall(function()
            Bridge.Error(res, 'INTERNAL_ERROR', 'internal error')
        end)
    end
end)

-- ---------------------------------------------------------------------------
-- Startup banner
-- ---------------------------------------------------------------------------

CreateThread(function()
    Wait(1000)

    local port = GetConvar('netPort', '30120')
    Utils.Log('info', ('http bridge mounted at http://127.0.0.1:%s/%s'):format(port, GetCurrentResourceName()))

    local routeNames = {}
    for key in pairs(routes) do
        routeNames[#routeNames + 1] = key
    end
    table.sort(routeNames)
    Utils.Log('info', ('%d routes registered'):format(#routeNames))
end)
