--[[
    hexa_mcp_bridge - console capture and command execution

    Console output is captured with RegisterConsoleListener into a bounded ring
    buffer. Error-looking lines are additionally classified into a second buffer
    so `get_resource_errors` has structured data even when the on-disk log is
    unavailable.

    IMPORTANT: never print() from inside the listener. The listener sees its own
    output and would recurse until the server dies.
]]

Hexa.Console = {}

local Console = Hexa.Console
local Utils = Hexa.Utils

local lines = Utils.NewRingBuffer(Config.ConsoleBufferSize or 2000)
local errors = Utils.NewRingBuffer(Config.ErrorBufferSize or 300)

-- Set while execute_console_command is capturing; nil the rest of the time.
local captureSink = nil

-- ---------------------------------------------------------------------------
-- Classification
-- ---------------------------------------------------------------------------

local ERROR_PATTERNS = {
    { kind = 'missing-dependency', pattern = 'could not find dependency ([%w_%.%-]+) for resource ([%w_%.%-]+)', resourceGroup = 2 },
    { kind = 'load-failure',       pattern = 'error loading script .- in resource ([%w_%.%-]+)',                 resourceGroup = 1 },
    { kind = 'load-failure',       pattern = 'failed to load resource ([%w_%.%-]+)',                             resourceGroup = 1 },
    { kind = 'load-failure',       pattern = "couldn't start resource ([%w_%.%-]+)",                             resourceGroup = 1 },
    { kind = 'manifest-error',     pattern = 'failed to parse resource manifest.-([%w_%.%-]+)',                  resourceGroup = 1 },
}

local GENERIC_ERROR_MARKERS = {
    'script error',
    'unhandled exception',
    'stack traceback',
    'attempt to index',
    'attempt to call',
    'attempt to compare',
    'attempt to perform',
    'error loading',
    'failed to load',
    'could not find dependency',
    'access denied',
    'econnrefused',
}

local IGNORE_MARKERS = {
    'hitch warning',
    'deprecated',
}

--- Extract `hexa_core` from `[    script:hexa_core] ...` or from the channel name.
---@param channel string
---@param message string
---@return string
local function resourceFromLine(channel, message)
    local fromMessage = message:match('%[%s*script:([%w_%.%-]+)%s*%]')
    if fromMessage then return fromMessage end

    local fromChannel = channel:match('^script:([%w_%.%-]+)$')
    if fromChannel then return fromChannel end

    return 'unknown'
end

---@param message string lowercase
---@return boolean
local function looksIgnorable(message)
    for _, marker in ipairs(IGNORE_MARKERS) do
        if message:find(marker, 1, true) then
            return true
        end
    end
    return false
end

---@param channel string
---@param message string
---@return string|nil kind
---@return string|nil resource
local function classify(channel, message)
    local lowered = message:lower()

    if looksIgnorable(lowered) then
        return nil
    end

    for _, entry in ipairs(ERROR_PATTERNS) do
        local a, b = lowered:match(entry.pattern)
        if a then
            local resource = entry.resourceGroup == 2 and b or a
            return entry.kind, resource or resourceFromLine(channel, message)
        end
    end

    for _, marker in ipairs(GENERIC_ERROR_MARKERS) do
        if lowered:find(marker, 1, true) then
            return 'script-error', resourceFromLine(channel, message)
        end
    end

    return nil
end

---@param message string lowercase
---@return string
local function severity(message)
    if message:find('error', 1, true) or message:find('exception', 1, true) then
        return 'error'
    end
    if message:find('warn', 1, true) then
        return 'warn'
    end
    return 'info'
end

-- ---------------------------------------------------------------------------
-- Listener
-- ---------------------------------------------------------------------------

RegisterConsoleListener(function(channel, message)
    -- No print(), no error(), no yielding in here.
    if type(message) ~= 'string' or message == '' then
        return
    end

    local text = Utils.StripColours(message):gsub('[\r\n]+$', '')
    if text == '' then
        return
    end

    local safeChannel = type(channel) == 'string' and channel or 'unknown'
    local now = os.time()

    lines:push({
        time = now,
        channel = safeChannel,
        message = text,
        level = severity(text:lower()),
    })

    if captureSink then
        captureSink[#captureSink + 1] = text
    end

    local kind, resource = classify(safeChannel, text)
    if kind then
        errors:push({
            time = now,
            resource = resource or 'unknown',
            message = text,
            kind = kind,
        })
    end
end)

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

--- Newest `limit` console lines, oldest first.
---@param limit number
---@param filter string|nil substring
---@param level string|nil 'info' | 'warn' | 'error'
---@return table
function Console.GetLines(limit, filter, level)
    local predicate = nil
    if filter or level then
        predicate = function(item)
            if level and item.level ~= level then
                return false
            end
            if filter and not (Utils.Contains(item.message, filter) or Utils.Contains(item.channel, filter)) then
                return false
            end
            return true
        end
    end

    return {
        lines = lines:tail(limit, predicate),
        buffered = lines.count,
        dropped = lines.dropped,
    }
end

--- Newest `limit` classified errors, oldest first.
---@param limit number
---@param resource string|nil
---@return table
function Console.GetErrors(limit, resource)
    local predicate = nil
    if resource then
        local wanted = resource:lower()
        predicate = function(item)
            return item.resource:lower() == wanted
        end
    end

    return errors:tail(limit, predicate)
end

--- Record an error the bridge itself detected (resource start failures, etc).
---@param resource string
---@param message string
---@param kind string
function Console.RecordError(resource, message, kind)
    errors:push({
        time = os.time(),
        resource = resource,
        message = message,
        kind = kind,
    })
end

-- ---------------------------------------------------------------------------
-- Command execution
-- ---------------------------------------------------------------------------

--- Is this verb allowed right now? Deny list wins over the allow list.
---@param command string
---@return boolean
---@return string|nil reason
function Console.IsCommandAllowed(command)
    if not Config.AllowConsoleCommands then
        return false, 'console commands are disabled in config.lua (Config.AllowConsoleCommands)'
    end

    local lowered = command:lower()

    if Utils.InList(Config.DeniedCommands, lowered, true) then
        return false, ('command "%s" is on the permanent deny list'):format(lowered)
    end

    if not Utils.InList(Config.AllowedCommands, lowered, true) then
        return false, ('command "%s" is not in Config.AllowedCommands'):format(lowered)
    end

    return true
end

--- Execute an allowlisted console command and capture the output that follows.
---
--- The command string is assembled from a validated bare verb plus validated
--- bare arguments, then handed to ExecuteCommand() - the FXServer console. No OS
--- shell, no os.execute, no io.popen is involved anywhere in this path.
---@param command string already validated and allowlisted
---@param args table already validated
---@param callback function(output: table)
function Console.Execute(command, args, callback)
    local parts = { command }
    for _, arg in ipairs(args) do
        parts[#parts + 1] = arg
    end
    local line = table.concat(parts, ' ')

    local sink = {}
    captureSink = sink

    ExecuteCommand(line)

    CreateThread(function()
        Wait(Config.CommandCaptureMs or 1200)
        captureSink = nil

        -- Cap the captured output so one chatty command cannot blow up a response.
        local output = {}
        local start = math.max(1, #sink - 200 + 1)
        for index = start, #sink do
            output[#output + 1] = sink[index]
        end

        callback(output)
    end)
end
