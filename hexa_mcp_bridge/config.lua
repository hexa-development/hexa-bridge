--[[
    hexa_mcp_bridge - configuration

    This file is committed to git, so it must never contain the API key.
    The key is read from a server convar instead:

        set hexa_mcp_api_key "your-32-char-or-longer-key"

    Put that line in a cfg file that is NOT committed (keys.cfg is already
    git-ignored in this repo layout).

    Every gate below is a second, independent check. The MCP server has its own
    permission matrix in config/permissions.json; an operation only happens when
    BOTH sides allow it. Turning something off here is always the stronger
    statement - the game server has the final word.
]]

Config = {}

-- Master switch. false = the HTTP handler answers 503 for everything.
Config.Enabled = true

-- Shared secret with the MCP server. Never hardcode it here.
Config.ApiKey = GetConvar('hexa_mcp_api_key', '')

-- Only these addresses may talk to the bridge. The MCP server normally runs on
-- the same machine as FXServer, so the default is loopback only.
-- Use '*' to disable the check (strongly discouraged).
Config.AllowedIPs = {
    '127.0.0.1',
    '::1'
}

-- ---------------------------------------------------------------------------
-- Capability gates
-- ---------------------------------------------------------------------------

-- Read operations. Turning one off makes the matching MCP tool fail with FORBIDDEN.
Config.AllowReadStatus     = true
Config.AllowReadPlayers    = true
Config.AllowReadResources  = true
Config.AllowReadConsole    = true

-- Resource lifecycle control.
Config.AllowResourceStart   = true
Config.AllowResourceStop    = true
Config.AllowResourceRestart = true

-- Dangerous. Off by default.
Config.AllowConsoleCommands = false
Config.AllowServerRestart   = false
Config.AllowPlayerKick      = false

-- ---------------------------------------------------------------------------
-- Console command allowlist
-- ---------------------------------------------------------------------------

-- Only these verbs may ever be executed, and only when AllowConsoleCommands is
-- true. Commands are run through ExecuteCommand() - the FXServer console - never
-- through an OS shell.
Config.AllowedCommands = {
    'status',
    'refresh',
    'ensure',
    'restart',
    'start',
    'stop'
}

-- Verbs that are refused even if someone adds them to AllowedCommands above.
-- These can hand over server authority or rewrite configuration.
Config.DeniedCommands = {
    'quit',
    'exec',
    'add_ace',
    'add_principal',
    'remove_ace',
    'remove_principal',
    'set',
    'sets',
    'setr',
    'rcon_password',
    'sv_licensekey',
    'endpoint_add_tcp',
    'endpoint_add_udp',
    'load_server_icon',
    'con_addchannelfilter',
    'txadmin'
}

-- Resources that may never be started, stopped or restarted through the bridge.
-- Stopping any of these would break the server or lock the bridge out of itself.
Config.ProtectedResources = {
    'hexa_mcp_bridge',
    'sessionmanager-rdr3',
    'spawnmanager',
    'mapmanager',
    'hardcap',
    'monitor'          -- txAdmin's in-server resource
}

-- ---------------------------------------------------------------------------
-- Disclosure policy
-- ---------------------------------------------------------------------------

-- What may be revealed about players.
--   'none'   - no identifiers at all
--   'masked' - steam:1100...9980 (enough to correlate, not enough to impersonate)
--   'full'   - raw identifiers
Config.PlayerIdentifiers = 'masked'

-- Player IP address / endpoint. Off by default: it is personal data.
Config.PlayerEndpoint = false

-- Identifier prefixes that are never disclosed, not even masked.
Config.HiddenIdentifierTypes = {
    'ip'
}

-- ---------------------------------------------------------------------------
-- Limits
-- ---------------------------------------------------------------------------

-- Console ring buffer size. Older lines are dropped.
Config.ConsoleBufferSize = 2000

-- Resource error ring buffer size.
Config.ErrorBufferSize = 300

-- Hard ceiling on lines returned in one response.
Config.MaxLogLines = 1000

-- Maximum request body size in bytes.
Config.MaxRequestBytes = 16 * 1024

-- Per-IP rate limits, requests per minute, by tier.
Config.RateLimit = {
    read      = 200,
    write     = 40,
    dangerous = 10
}

-- Seconds to wait after a start/stop before reading the resource state back.
-- FXServer state transitions are not instantaneous.
Config.StateSettleMs = 750

-- How long to keep capturing console output after execute_console_command.
Config.CommandCaptureMs = 1200

-- ---------------------------------------------------------------------------
-- Framework
-- ---------------------------------------------------------------------------

-- Reported to the MCP server so it can pick a framework adapter.
-- 'auto' detects hexa_core / vorp_core / rsg-core from the started resources.
-- Force a value here if detection guesses wrong.
Config.Framework = 'auto'

-- ---------------------------------------------------------------------------
-- Audit
-- ---------------------------------------------------------------------------

-- Print an AUDIT line to the server console for every state-changing request.
-- txAdmin captures the console, so this lands in fxserver.log automatically and
-- the MCP server writes its own copy to logs/audit.log.
Config.AuditToConsole = true

-- Print a line for read requests too. Very noisy - debugging only.
Config.AuditReads = false
