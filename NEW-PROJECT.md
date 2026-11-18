# Standard for every project of A-Delnaz (instructions for Claude)

Read this when a new project starts, or when an existing project is moved to this standard.

## 1. Where the code lives

- Write the code directly to the project's private GitHub repository (github.com/A-Delnaz/<Project>).
- The user does not copy code by hand. On his PC he only uses dev.cmd.
- If the project uses a work branch, write to it (for example `dev`) and let the user publish with dev.cmd.

## 2. Files every project gets

| File | What |
|---|---|
| `dev.cmd` | Copy it unchanged from this repository. Never write a project-specific dev.cmd or dev.ps1. |
| `dev.json` | Project settings for the tool (see README.md and dev.example.json). |
| `.gitignore` | At least: `.env`, `venv/`, `.venv/`, `__pycache__/`, `*.pyc`, `db.sqlite3`, `media/`, `.local/`, `bin/`, `obj/` (what fits the type). |
| `.gitattributes` | `*.cmd`, `*.bat`, `*.ps1` with `eol=crlf`. |
| `.env.example` | Every setting with an empty or example value. Real values only in `.env`. |
| `VERSION` + `CHANGELOG.md` | Version number (MAJOR.MINOR.PATCH) and the change list in Persian, newest first. |
| `CLAUDE.md` | Rules of the project for later chats (Persian answers, versioning, how to publish). |

## 3. dev.json rules

- `port`: a port that no other project of the user has. Known ports:
  CCTV-Status 8000, Shadow-GameNet 8001, Security-Reports 8002, ShadowGN-WebSite 8003, Domainator 5069.
  New projects: 8004 and up (and add them to this list).
- `setup_commands` must be safe to run again; `seed_commands` only create default data.
- Extra project scripts (build, release) go into `tools`, not into a new launcher.

## 4. Django projects

- `SESSION_COOKIE_NAME` and `CSRF_COOKIE_NAME` with the project's own prefix, so several sites
  can run on one PC without logging each other out.
- Read `APP_DEV=1` (set by dev.cmd) if the project needs a different database on the developer PC.
- Every model change has a migration.

## 5. Working with the user

- Answers in Persian, short sentences, few English words (in parentheses), code in separate blocks.
- He is not a programmer: give complete files and say exactly what to replace.
- Messages printed by terminal scripts (PowerShell, bash) are in English.
- Changes to the dev tool itself are made only in this repository (dev-tools), then pushed.

## 6. Updates for installed servers

The shared update system (signed and encrypted packages, release repository per product,
licence with support end date, update folder for offline networks) is being built.
Until it is ready, keep the project's current update method.
