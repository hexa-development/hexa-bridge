<div align="center">

# HEXA BRIDGE

### Compatibility layer for the Hexa Framework

Run supported **RSG Core** and **VORP Core** resources on top of [`hexa_core`](https://github.com/hexa-development/hexa_core) with minimal or no changes to the original script.

<br>

[![Documentation](https://img.shields.io/badge/Documentation-Hexa_Docs-B45309?style=for-the-badge)](https://hexa-development.github.io/hexa-docs/)
[![RedM](https://img.shields.io/badge/Platform-RedM-8B0000?style=for-the-badge)](https://redm.net/)
[![Lua](https://img.shields.io/badge/Lua-5.4-2C2D72?style=for-the-badge\&logo=lua\&logoColor=white)](https://www.lua.org/)

<br>

**RSG Compatibility · VORP Compatibility · Hexa Core**

</div>

---

## About

**hexa-bridge** is a compatibility layer for [`hexa_core`](https://github.com/hexa-development/hexa_core).

It allows supported resources originally developed for other RedM frameworks to communicate with Hexa through familiar APIs, exports, events, and framework objects.

Instead of loading the original framework alongside Hexa, the bridge emulates the APIs commonly expected by those resources.

```text
Existing RSG / VORP Resource
            │
            ▼
    ┌─────────────────┐
    │   hexa-bridge   │
    └────────┬────────┘
             │
             ▼
    ┌─────────────────┐
    │    hexa_core    │
    └─────────────────┘
```

The goal is to make framework migration easier without forcing you to rewrite every existing resource at once.

---

## Supported Bridges

| Resource        | Compatibility                                               |
| :-------------- | :---------------------------------------------------------- |
| **`rsg-core`**  | Emulates commonly used RSG Core APIs on top of `hexa_core`  |
| **`vorp_core`** | Emulates commonly used VORP Core APIs on top of `hexa_core` |

---

## RSG Core Bridge

The `rsg-core` bridge uses the same resource name expected by RSG scripts.

Existing resources can continue requesting the core object normally:

```lua
local RSGCore = exports['rsg-core']:GetCoreObject()
```

Internally, the bridge translates supported RSG operations into their Hexa equivalents.

```text
RSG Script
    │
    │ exports['rsg-core']:GetCoreObject()
    ▼
rsg-core Bridge
    │
    ▼
hexa_core
```

The bridge is **not the original RSG Core**.

It provides a compatibility API designed specifically for running supported RSG resources on Hexa.

---

## VORP Core Bridge

The `vorp_core` bridge provides compatibility for commonly used VORP Core APIs.

For example:

```lua
local VorpCore = exports.vorp_core:GetCore()
```

Supported compatibility may include APIs such as:

```text
GetCore
getCore
AddWebhook
Player APIs
Character APIs
Callbacks
Events
```

Exact compatibility depends on the bridge version and API being used.

The bridge is **not the original VORP Core**.

---

## Installation

Place the bridge resources inside your RedM server resources directory.

Example:

```text
resources/
│
└── [scripts-hexa]/
    │
    ├── hexa_core/
    │
    └── [bridge]/
        ├── rsg-core/
        └── vorp_core/
```

Then configure your `server.cfg`.

### Using RSG resources

```ini
ensure hexa_core
ensure rsg-core
```

### Using VORP resources

```ini
ensure hexa_core
ensure vorp_core
```

### Using both bridges

```ini
ensure hexa_core

ensure rsg-core
ensure vorp_core
```

Always start bridge resources **after `hexa_core`**.

---

> [!IMPORTANT]
> **Do not run a Hexa bridge together with the original framework core using the same resource name.**
>
> For example, never start both the Hexa `rsg-core` bridge and the real `rsg-core`.
>
> The resource names intentionally match the original frameworks so existing scripts can resolve their exports without modification.

---

## How It Works

A resource originally written for RSG might contain:

```lua
local RSGCore = exports['rsg-core']:GetCoreObject()

local Player = RSGCore.Functions.GetPlayer(source)
```

With the Hexa RSG bridge installed, that request is intercepted by the compatibility resource.

```text
Resource
   │
   ▼
exports['rsg-core']
   │
   ▼
Hexa RSG Bridge
   │
   ▼
Hexa API Translation
   │
   ▼
hexa_core
```

The same idea applies to supported VORP APIs.

This allows the existing resource to keep using the interface it expects while Hexa remains the actual server framework underneath.

---

## Why hexa-bridge?

Migrating an established RedM server can involve dozens or even hundreds of framework-specific API calls.

Without a compatibility layer:

```text
Old Resource
     │
     ▼
Rewrite API calls
     │
     ▼
Rewrite player logic
     │
     ▼
Rewrite callbacks
     │
     ▼
Rewrite framework events
     │
     ▼
Test everything again
```

With `hexa-bridge`:

```text
Old Resource
     │
     ▼
hexa-bridge
     │
     ▼
hexa_core
```

This makes it possible to migrate resources progressively instead of treating a framework change as an all-or-nothing rewrite.

---

## Compatibility Scope

The bridges focus on APIs commonly used by RedM resources, including areas such as:

* Core object access
* Player retrieval
* Character data
* Money operations
* Job information
* Metadata
* Callbacks
* Events
* Shared data
* Utility functions
* Framework-specific exports

Compatibility is expanded as additional real-world resources and API patterns are tested.

---

## Limitations

`hexa-bridge` is a compatibility layer, **not a complete reimplementation of RSG Core or VORP Core**.

Some resources may depend on:

* undocumented framework behavior
* internal framework state
* uncommon exports
* framework-specific database structures
* direct SQL queries against original framework tables
* resources tightly coupled to other framework modules

These resources may still require adjustments.

If a script uses an API that is not currently supported, please report it so compatibility can be expanded.

---

## Compatibility Philosophy

The bridge follows a simple rule:

> **Emulate the interface — keep Hexa as the actual framework.**

Compatibility logic should stay inside the bridge whenever possible.

This prevents `hexa_core` from becoming dependent on another framework's internal architecture and keeps the Hexa API clean for native Hexa resources.

For new resources, using the native Hexa API directly is recommended:

```lua
local HexaCore = exports['hexa_core']:GetCoreObject()
```

Use bridges primarily when maintaining or migrating resources originally written for another framework.

---

## Documentation

Installation instructions, supported APIs, migration information, and compatibility references are available in the official Hexa documentation.

### [Open Hexa Documentation →](https://hexa-development.github.io/hexa-docs/)

---

## Reporting Missing APIs

Found a resource that calls an unsupported RSG or VORP function?

When opening an issue, include:

```text
Framework:
Resource:
Missing export / function:
Expected behavior:
Error message:
Relevant code:
```

Providing the exact API call makes compatibility issues significantly easier to reproduce and implement.

---

## Hexa Ecosystem

The bridge is the migration path into the Hexa Framework stack. Each part is its own repository.

| Project | Description |
| :--- | :--- |
| [`hexa_core`](https://github.com/hexa-development/hexa_core) | Core framework — players, jobs, items, economy, status, callbacks, permissions |
| [`hexa_inventory`](https://github.com/hexa-development/hexa_inventory) | Persistent grid inventory — stashes, shops, ground drops, secure trading |
| [`hexa_progbar`](https://github.com/hexa-development/hexa_progbar) | Screen-fixed progress bar — drop-in for `ox_lib` `progressBar` |
| **`hexa-bridge`** | Compatibility layer for supported RSG and VORP resources <br> *(this repository)* |
| [`hexa-docs`](https://github.com/hexa-development/hexa-docs) | Official documentation and API reference (VitePress) |
| [`rdr2-unpack`](https://github.com/hexa-development/rdr2-unpack) | Read a local RDR2 install into open formats — GLB, PNG, `.ymap` JSON |
| [`txAdmin`](https://github.com/hexa-development/txAdmin) | One-click txAdmin recipe that deploys the whole Hexa stack |

Full API reference and installation guides live in [`hexa-docs`](https://github.com/hexa-development/hexa-docs) → [hexa-development.github.io/hexa-docs](https://hexa-development.github.io/hexa-docs/)

---

## License

Free to use for RedM server development.

You may use, modify, and distribute the bridge according to the license included with this repository.

---

<div align="center">

### Migrate progressively. Rewrite only when necessary.

**Built for Hexa Framework**

<br>

[Documentation](https://hexa-development.github.io/hexa-docs/) ·
[เอกสารภาษาไทย](https://hexa-development.github.io/hexa-docs/th/) ·
[hexa_core](https://github.com/hexa-development/hexa_core) ·
[hexa_inventory](https://github.com/hexa-development/hexa_inventory) ·
[hexa_progbar](https://github.com/hexa-development/hexa_progbar) ·
[hexa-bridge](https://github.com/hexa-development/hexa-bridge) ·
[Organization](https://github.com/hexa-development)

</div>
