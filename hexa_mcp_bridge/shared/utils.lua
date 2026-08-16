--[[
    hexa_mcp_bridge - shared helpers

    Loaded first, so everything below is available to every other file.
]]

Hexa = Hexa or {}
Hexa.Utils = {}

local Utils = Hexa.Utils

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------

local RESOURCE = GetCurrentResourceName()

--- Console print with a consistent prefix.
--- Never call this from inside a console listener - it would recurse forever.
---@param level string 'info' | 'warn' | 'error'
---@param message string
function Utils.Log(level, message)
    local colour = '^7'
    if level == 'warn' then
        colour = '^3'
    elseif level == 'error' then
        colour = '^1'
    elseif level == 'info' then
        colour = '^2'
    end
    print(('%s[%s]^7 %s'):format(colour, RESOURCE, message))
end

-- ---------------------------------------------------------------------------
-- String helpers
-- ---------------------------------------------------------------------------

--- Trim leading and trailing whitespace.
---@param value string|nil
---@return string
function Utils.Trim(value)
    if type(value) ~= 'string' then return '' end
    return (value:gsub('^%s*(.-)%s*$', '%1'))
end

--- Case-insensitive "does haystack contain needle".
---@param haystack string
---@param needle string
---@return boolean
function Utils.Contains(haystack, needle)
    if type(haystack) ~= 'string' or type(needle) ~= 'string' or needle == '' then
        return false
    end
    return haystack:lower():find(needle:lower(), 1, true) ~= nil
end

--- Strip FXServer colour codes (^1..^9) so log lines stay readable for an AI.
---@param value string
---@return string
function Utils.StripColours(value)
    if type(value) ~= 'string' then return '' end
    return (value:gsub('%^%d', ''))
end

--- Does `list` contain `value`? Optionally case-insensitive.
---@param list table
---@param value any
---@param caseInsensitive boolean|nil
---@return boolean
function Utils.InList(list, value, caseInsensitive)
    if type(list) ~= 'table' then return false end
    for _, item in ipairs(list) do
        if item == value then
            return true
        end
        if caseInsensitive and type(item) == 'string' and type(value) == 'string' then
            if item:lower() == value:lower() then
                return true
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

--- Resource names: letters, digits, underscore, hyphen and dot only.
--- This is what rejects `hexa_inventory; quit` and `../../server.cfg`.
---@param name any
---@return boolean, string|nil
function Utils.IsValidResourceName(name)
    if type(name) ~= 'string' then
        return false, 'resource name must be a string'
    end
    if #name < 1 or #name > 64 then
        return false, 'resource name length must be between 1 and 64'
    end
    if not name:match('^[%w_%.%-]+$') then
        return false, 'resource name contains characters that are not allowed'
    end
    if name:find('%.%.', 1) then
        return false, 'resource name may not contain ".."'
    end
    return true
end

--- Console verbs are a single bare word.
---@param command any
---@return boolean, string|nil
function Utils.IsValidCommandWord(command)
    if type(command) ~= 'string' then
        return false, 'command must be a string'
    end
    if #command < 1 or #command > 32 then
        return false, 'command length must be between 1 and 32'
    end
    if not command:match('^[%w_]+$') then
        return false, 'command must be a single bare word'
    end
    return true
end

--- Console arguments: no spaces, quotes, semicolons or shell metacharacters, so
--- a second command can never be smuggled in.
---@param arg any
---@return boolean, string|nil
function Utils.IsValidCommandArg(arg)
    if type(arg) ~= 'string' then
        return false, 'argument must be a string'
    end
    if #arg < 1 or #arg > 64 then
        return false, 'argument length must be between 1 and 64'
    end
    if not arg:match('^[%w_%.%:%-]+$') then
        return false, 'argument contains characters that are not allowed'
    end
    return true
end

--- Coerce to a positive integer within bounds, or nil.
---@param value any
---@param min number
---@param max number
---@return number|nil
function Utils.ToBoundedInt(value, min, max)
    local number = tonumber(value)
    if not number then return nil end
    number = math.floor(number)
    if number < min or number > max then return nil end
    return number
end

--- Reason / free text: printable characters only, length capped.
---@param value any
---@param maxLength number
---@return string|nil
function Utils.SanitiseText(value, maxLength)
    if type(value) ~= 'string' then return nil end
    local trimmed = Utils.Trim(value)
    if trimmed == '' then return nil end
    -- Drop control characters outright rather than escaping them.
    trimmed = trimmed:gsub('[%c]', ' ')
    if #trimmed > maxLength then
        trimmed = trimmed:sub(1, maxLength)
    end
    return trimmed
end

-- ---------------------------------------------------------------------------
-- Identifier masking
-- ---------------------------------------------------------------------------

--- steam:110000112de2998 -> steam:1100...2998
---@param identifier string
---@return string
function Utils.MaskIdentifier(identifier)
    local prefix, value = identifier:match('^(%w+):(.*)$')
    if not prefix or not value then
        return 'unknown'
    end
    if #value <= 10 then
        return ('%s:%s'):format(prefix, ('*'):rep(#value))
    end
    return ('%s:%s...%s'):format(prefix, value:sub(1, 4), value:sub(-4))
end

-- ---------------------------------------------------------------------------
-- Ring buffer
-- ---------------------------------------------------------------------------

--- Fixed-size FIFO. Used for the console and error buffers so memory is bounded
--- no matter how noisy the server gets.
---@param capacity number
---@return table
function Utils.NewRingBuffer(capacity)
    return {
        items = {},
        capacity = capacity,
        first = 1,
        count = 0,
        dropped = 0,
        seq = 0,

        push = function(self, item)
            self.seq = self.seq + 1
            item.seq = self.seq

            if self.count < self.capacity then
                self.items[(self.first + self.count - 1) % self.capacity + 1] = item
                self.count = self.count + 1
            else
                self.items[self.first] = item
                self.first = self.first % self.capacity + 1
                self.dropped = self.dropped + 1
            end
        end,

        --- Newest `limit` items, oldest first.
        ---@param limit number
        ---@param predicate function|nil
        ---@return table
        tail = function(self, limit, predicate)
            local matched = {}
            for offset = 0, self.count - 1 do
                local index = (self.first + offset - 1) % self.capacity + 1
                local item = self.items[index]
                if item and (not predicate or predicate(item)) then
                    matched[#matched + 1] = item
                end
            end

            local total = #matched
            if total <= limit then
                return matched
            end

            local out = {}
            for index = total - limit + 1, total do
                out[#out + 1] = matched[index]
            end
            return out
        end
    }
end

-- ---------------------------------------------------------------------------
-- Time
-- ---------------------------------------------------------------------------

--- Unix seconds.
---@return number
function Utils.Now()
    return os.time()
end

--- ISO-8601 UTC timestamp for audit lines.
---@return string
function Utils.Timestamp()
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end
