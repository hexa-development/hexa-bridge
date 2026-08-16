fx_version 'cerulean'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
game 'rdr3'

lua54 'yes'

name 'hexa_mcp_bridge'
author 'Hexa Development'
description 'HTTP bridge that exposes read-only status and guarded control operations to the hexa_mcp MCP server'
version '1.0.0'

-- Server side only. This resource has no client footprint by design: nothing it
-- does should be reachable from a game client.
server_scripts {
    'shared/utils.lua',
    'config.lua',
    'server/auth.lua',
    'server/console.lua',
    'server/resources.lua',
    'server/players.lua',
    'server/bridge.lua',
    'server/main.lua'
}

-- No files, no client_scripts, no exports to the client.
