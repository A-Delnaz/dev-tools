# Projects of A-Delnaz: which ones are licensed products

Every chat that works on a project reads that project's CLAUDE.md, which points here.
If a project is not in this list, ask the user before adding licences or the update system.

| Repository | Kind | Licence | Product id | Modules | Release repository | Port |
|---|---|---|---|---|---|---|
| Security-Reports | Software (Django, Windows server) | **Yes** | `security-reports` | none yet (one licence = whole program) | Security-Reports-Releases | 8002 |
| Network-Status | Software (Django, Ubuntu server) | **Yes** | `network-status` | none yet | Network-Status-Releases (not created yet) | 8000 |
| Domainator | Software (.NET, Windows server) | **Yes, modular** | `domainator` | `ca` (certificates), `dns`, `gpo` (Group Policy), `aduc` (Users & Computers). Later: `wsus` and other Microsoft services. Devices, events, jobs and settings belong to the base (always on). | Domainator-Releases | 5069 |
| Shadow-GameNet | Management app of the user's own game-net | No (user's own; may change later) | — | — | — | 8001 |
| ShadowGN-WebSite | Public website | No | — | — | — | 8003 |
| Raja-Lightning | Online shop (Docker, updates itself from GitHub) | No | — | — | — | — |

## What "licensed product" means for a chat working on it

1. Read docs/UPDATES-AND-LICENSES.md (decisions, file formats, status table).
2. New features that belong to a module must be checked against the licence (hidden in the menu and refused on the server side)
   once the licence check exists in that product. Ask the user which module a new feature belongs to if it is not clear.
3. Releases use the .adup update packages and the product's release repository (when that part is marked done).
4. Never put private keys in the repository. Public keys and the product content key live in `update-keys.json`.

## Websites (no licence)

They are the user's own sites. No licence check, no .adup packages. They keep their own update method.
