--[[
    คลาส Locale — เหมือนกับ rsg-core/qb-core ตัวจริงทุกอย่าง
    มีไว้ให้สคริปต์ที่ประกาศ '@rsg-core/shared/locale.lua' ใน fxmanifest
    โหลดได้ตามปกติ แล้วใช้ Lang = Locale:new({ phrases = ..., ... }) / Lang:t(key)

    ไฟล์นี้อยู่ใน files{} ของ fxmanifest ด้วย — ไม่งั้น client ของ resource อื่น
    จะโหลด '@rsg-core/shared/locale.lua' ไม่ได้ (พังเงียบ ๆ ฝั่ง client
    ส่วนฝั่ง server ผ่านปกติ ทำให้ไล่บั๊กยาก)
]]

--- @class Locale
Locale = {}
Locale.__index = Locale

local function translateKey(phrase, subs)
    if type(phrase) ~= 'string' then
        error('TypeError: translateKey function expects arg #1 to be a string')
    end

    if not subs then
        return phrase
    end

    local result = phrase

    for k, v in pairs(subs) do
        local templateToFind = '%%{' .. k .. '}'
        result = result:gsub(templateToFind, tostring(v))
    end

    return result
end

--- @param opts table<string, any>
--- @return Locale
function Locale.new(_, opts)
    local self = setmetatable({}, Locale)

    self.fallback = opts.fallbackLang and Locale:new({
        warnOnMissing = false,
        phrases = opts.fallbackLang.phrases,
    }) or false

    self.warnOnMissing = type(opts.warnOnMissing) ~= 'boolean' and true or opts.warnOnMissing

    self.phrases = {}
    self:extend(opts.phrases or {})

    return self
end

--- @param phrases table<string, string>
--- @param prefix string | nil
--- @return nil
function Locale:extend(phrases, prefix)
    for key, phrase in pairs(phrases) do
        local prefixKey = prefix and ('%s.%s'):format(prefix, key) or key
        if type(phrase) == 'table' then
            self:extend(phrase, prefixKey)
        else
            self.phrases[prefixKey] = phrase
        end
    end
end

--- @return nil
function Locale:clear()
    self.phrases = {}
end

--- @param phrases table<string, any>
function Locale:replace(phrases)
    phrases = phrases or {}
    self:clear()
    self:extend(phrases)
end

--- @param newLocale string
--- @return string
function Locale:locale(newLocale)
    if (newLocale) then
        self.currentLocale = newLocale
    end
    return self.currentLocale
end

--- @param key string
--- @param subs table<string, any> | nil
--- @return string
function Locale:t(key, subs)
    local phrase, result
    subs = subs or {}

    if type(self.phrases[key]) == 'string' then
        phrase = self.phrases[key]
    else
        if self.warnOnMissing then
            print(('^3Warning: Missing phrase for key: "%s"'):format(key))
        end
        if self.fallback then
            return self.fallback:t(key, subs)
        end
        result = key
    end

    if type(phrase) == 'string' then
        result = translateKey(phrase, subs)
    end

    return result
end

--- @return boolean
function Locale:has(key)
    return self.phrases[key] ~= nil
end

--- @param phraseTarget string | table
--- @param prefix string
function Locale:delete(phraseTarget, prefix)
    if type(phraseTarget) == 'string' then
        self.phrases[phraseTarget] = nil
    else
        for key, phrase in pairs(phraseTarget) do
            local prefixKey = prefix and prefix .. '.' .. key or key

            if type(phrase) == 'table' then
                self:delete(phrase, prefixKey)
            else
                self.phrases[prefixKey] = nil
            end
        end
    end
end
