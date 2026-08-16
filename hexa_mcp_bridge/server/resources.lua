--[[
    hexa_mcp_bridge - resource inspection and lifecycle control

    Everything here goes through the FXServer resource natives
    (GetResourceState / StartResource / StopResource). No console command string
    is ever built from input, so there is nothing to inject into.

    Every action follows the same contract:
        validate name -> resource exists -> not protected -> read current state
                      -> perform          -> settle        -> verify final state
]]

Hexa.Resources = {}

local Resources = Hexa.Resources
local Utils = Hexa.Utils

local VALID_STATES = {
    started = true,
    starting = true,
    stopped = true,
    stopping = true,
    missing = true,
    uninitialized = true,
    unknown = true,
}

-- ---------------------------------------------------------------------------
-- Inspection
-- ---------------------------------------------------------------------------

---@param name string
---@return string
local function stateOf(name)
    local state = GetResourceState(name)
    if type(state) ~= 'string' or state == '' then
        return 'unknown'
    end
    if not VALID_STATES[state] then
        return 'unknown'
    end
    return state
end

Resources.StateOf = stateOf

--- Does FXServer know about this resource at all?
---@param name string
---@return boolean
function Resources.Exists(name)
    return stateOf(name) ~= 'missing'
end

--- Read a metadata entry from the resource's fxmanifest, or nil.
---@param name string
---@param key string
---@return string|nil
local function metadata(name, key)
    local ok, value = pcall(GetResourceMetadata, name, key, 0)
    if not ok or value == nil or value == '' then
        return nil
    end
    return value
end

--- All `dependency` entries declared in the manifest.
---@param name string
---@return table
local function dependencies(name)
    local out = {}
    local ok, count = pcall(GetNumResourceMetadata, name, 'dependency')
    if not ok or type(count) ~= 'number' then
        return out
    end

    for index = 0, count - 1 do
        local okValue, value = pcall(GetResourceMetadata, name, 'dependency', index)
        if okValue and type(value) == 'string' and value ~= '' then
            out[#out + 1] = value
        end
    end
    return out
end

--- Full description of a single resource.
---@param name string
---@return table
function Resources.Describe(name)
    return {
        name = name,
        state = stateOf(name),
        version = metadata(name, 'version'),
        author = metadata(name, 'author'),
        description = metadata(name, 'description'),
        dependencies = dependencies(name),
    }
end

--- Every resource FXServer knows about, optionally filtered by state.
---@param filterState string|nil
---@return table resources
---@return table summary counts keyed by state
function Resources.List(filterState)
    local out = {}
    local summary = { started = 0, starting = 0, stopped = 0, stopping = 0, missing = 0, unknown = 0, uninitialized = 0 }
    local total = GetNumResources()

    for index = 0, total - 1 do
        local name = GetResourceByFindIndex(index)
        if name and name ~= '' then
            local state = stateOf(name)
            summary[state] = (summary[state] or 0) + 1

            if not filterState or state == filterState then
                out[#out + 1] = Resources.Describe(name)
            end
        end
    end

    table.sort(out, function(a, b) return a.name < b.name end)
    return out, summary
end

--- started / stopped / total, for the status endpoint.
---@return table
function Resources.Counts()
    local started, stopped, total = 0, 0, 0

    for index = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(index)
        if name and name ~= '' then
            total = total + 1
            local state = stateOf(name)
            if state == 'started' then
                started = started + 1
            elseif state == 'stopped' or state == 'uninitialized' then
                stopped = stopped + 1
            end
        end
    end

    return { started = started, stopped = stopped, total = total }
end

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------

--- Protected resources may never be controlled through the bridge - stopping
--- any of them would break the server or lock the bridge out of itself.
---@param name string
---@return boolean
function Resources.IsProtected(name)
    return Utils.InList(Config.ProtectedResources, name, true)
end

---@param action string
---@return boolean
---@return string|nil reason
local function actionAllowed(action)
    if action == 'start' and not Config.AllowResourceStart then
        return false, 'resource start is disabled in config.lua'
    end
    if action == 'stop' and not Config.AllowResourceStop then
        return false, 'resource stop is disabled in config.lua'
    end
    if (action == 'restart' or action == 'ensure') and not Config.AllowResourceRestart then
        return false, 'resource restart is disabled in config.lua'
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

--- Wait for a resource to settle into a terminal state, or time out.
---@param name string
---@param wanted string
---@return string finalState
local function settle(name, wanted)
    local deadline = GetGameTimer() + (Config.StateSettleMs or 750)
    local state = stateOf(name)

    while GetGameTimer() < deadline do
        state = stateOf(name)
        if state == wanted then
            return state
        end
        -- Give up early on a state that will not change on its own.
        if state == 'missing' then
            return state
        end
        Wait(50)
    end

    return stateOf(name)
end

--- Perform a lifecycle action. Blocking - call from inside a thread.
---@param action string 'start' | 'stop' | 'restart' | 'ensure'
---@param name string
---@return table|nil result
---@return string|nil errorCode
---@return string|nil errorMessage
function Resources.Perform(action, name)
    local valid, reason = Utils.IsValidResourceName(name)
    if not valid then
        return nil, 'INVALID_INPUT', reason
    end

    local allowed, why = actionAllowed(action)
    if not allowed then
        return nil, 'FORBIDDEN', why
    end

    if Resources.IsProtected(name) then
        return nil, 'FORBIDDEN', ('resource "%s" is protected and cannot be controlled through hexa_mcp'):format(name)
    end

    local previousState = stateOf(name)
    if previousState == 'missing' then
        return nil, 'RESOURCE_NOT_FOUND', ('resource "%s" does not exist on this server'):format(name)
    end

    local finalState
    local effective = action

    if action == 'ensure' then
        effective = (previousState == 'started' or previousState == 'starting') and 'restart' or 'start'
    end

    if effective == 'start' then
        if previousState == 'started' then
            return {
                resource = name,
                action = action,
                previousState = previousState,
                state = previousState,
                verified = true,
            }
        end
        StopResource(name)  -- no-op when already stopped; guarantees a clean start
        Wait(50)
        StartResource(name)
        finalState = settle(name, 'started')

    elseif effective == 'stop' then
        if previousState == 'stopped' or previousState == 'uninitialized' then
            return {
                resource = name,
                action = action,
                previousState = previousState,
                state = previousState,
                verified = true,
            }
        end
        StopResource(name)
        finalState = settle(name, 'stopped')

    elseif effective == 'restart' then
        StopResource(name)
        settle(name, 'stopped')
        StartResource(name)
        finalState = settle(name, 'started')

    else
        return nil, 'INVALID_INPUT', ('unknown action "%s"'):format(tostring(action))
    end

    local expected = (effective == 'stop') and 'stopped' or 'started'
    local verified = finalState == expected

    if not verified then
        Hexa.Console.RecordError(name,
            ('%s did not reach state "%s" (currently "%s")'):format(action, expected, finalState),
            'lifecycle')
    end

    return {
        resource = name,
        action = action,
        previousState = previousState,
        state = finalState,
        verified = verified,
    }
end

-- ---------------------------------------------------------------------------
-- Startup failure capture
-- ---------------------------------------------------------------------------

--- A resource that stops immediately after starting almost always failed to
--- load. Record it so `get_resource_errors` can surface it even if the console
--- line was already rotated out.
AddEventHandler('onResourceStart', function(name)
    if name == GetCurrentResourceName() then return end

    CreateThread(function()
        Wait(3000)
        local state = stateOf(name)
        if state == 'stopped' or state == 'uninitialized' then
            Hexa.Console.RecordError(name, ('resource stopped immediately after starting (state=%s)'):format(state), 'startup')
        end
    end)
end)
