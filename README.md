# hexa-bridge

**Compatibility bridges** for [hexa_core](https://github.com/hexa-development/hexa_core) — run scripts written for other RedM frameworks on a Hexa server without modifying their code.

📖 Full documentation: [hexa-development.github.io/hexa-docs](https://hexa-development.github.io/hexa-docs/)

## What's included

| Resource | Description |
| --- | --- |
| **rsg-core** | RSG-Core API emulation bridge on top of hexa_core (not the real rsg-core) — RSG scripts can call `exports['rsg-core']:GetCoreObject()` as usual |
| **vorp_core** | VORP Core API emulation bridge on top of hexa_core (not the real vorp_core) — supports `getCore()`, `AddWebhook`, and more |

## Installation

Place the folder inside your server's resources directory, for example:

```
resources/[scripts-hexa]/[bridge]/
├── rsg-core/
└── vorp_core/
```

Then in `server.cfg` — start only the bridges you need, always **after** `hexa_core`:

```ini
ensure hexa_core

# pick the bridges matching the scripts you run
ensure rsg-core   # if you run RSG scripts
ensure vorp_core  # if you run VORP scripts
```

> [!IMPORTANT]
> Never start a bridge alongside the real core of that framework (e.g. the actual rsg-core) — the resource names collide by design.

## Limitations

The bridges cover the APIs most scripts rely on. If you hit a function that is not supported yet, please open an issue.

## License

Free for any RedM server — use, modify, and share as you like.
