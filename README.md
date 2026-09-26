<p align="center">
  <img src="images/chatter.png" alt="The Chatters" width="100%">
</p>

# Chatter Companion

Chatter is a World of Warcraft 3.3.5 addon that acts as a companion UI for the [`mod-llm-chatter`](https://github.com/Hokken/mod-llm-chatter) AzerothCore module.

It lets the player manage persistent personality traits for bots they have grouped with before. The addon shows known bots, allows editing the three stored traits for a selected bot, and displays the tone that `mod-llm-chatter` generates from those traits.

> **Repository:** https://github.com/Hokken/Chatter-Companion

---

## What It Does

- Lists bots the player has previously grouped with
- Lets the player edit each bot's 3 persistent traits
- Shows the generated tone derived from those traits
- Syncs with the server-side `mod-llm-chatter` data model

## Companion To mod-llm-chatter

This addon is **not a standalone system**. It only works against an AzerothCore server that has [`mod-llm-chatter`](https://github.com/Hokken/mod-llm-chatter) installed and running (worldserver + Python bridge). On a vanilla server the addon will load but the roster will stay empty and saving traits will do nothing.

## Requirements

- World of Warcraft 3.3.5a client
- AzerothCore server with `mod-llm-chatter` installed and the Python bridge running
- The server build must accept chunked trait uploads — see below
- You must have grouped with at least one bot before that bot appears in the roster

### Server support for long traits

The client cuts any outgoing chat line at 255 characters, which is not
always enough for three traits at their full 64-character limit once they
are percent-encoded. When a save does not fit, the addon uploads it in
pieces using the `put`, `commit` and `cancel` commands, and a server that
does not know those commands cannot accept it.

Traits containing emoji or other 4-byte UTF-8 characters also need a
current server. The client replaces `%f` in every outgoing chat line with
the focus target's name, so the addon sends those bytes as `~F0`–`~F4`
instead of `%F0`–`%F4`, and an older server does not decode them, so
those characters arrive garbled.

Short saves still work everywhere: the addon only splits an upload when it
has to, and otherwise sends the single-line `set` that every version of
`mod-llm-chatter` understands.

On a server without chunked-upload support the split save is refused, and
the addon treats that refusal like any other rejection: the upload stops,
the traits you typed stay in the boxes, and **Save Traits** stays available.
Nothing is lost — shorten the traits and save again, or update the server.

---

## Installation

The single most common reason the addon "does not show up in the AddOns menu" is a wrong folder layout. Follow these steps exactly.

### 1. Download

- Go to https://github.com/Hokken/Chatter-Companion
- Click **Code → Download ZIP**, or `git clone` the repo

### 2. Place the folder correctly

The addon folder must be at:

```
<WoW install>\Interface\AddOns\Chatter\
```

Inside that `Chatter` folder you must see:

```
Chatter\
├── Chatter.toc
├── Chatter.lua
├── README.md
└── images\
```

> **The folder name must be exactly `Chatter`** (matching `Chatter.toc`).
> If WoW does not see a folder whose name matches the `.toc` filename, the addon will not appear in the AddOns list.

#### Common mistakes

| Wrong layout | Why it fails | Fix |
|---|---|---|
| `Interface\AddOns\Chatter-Companion-master\Chatter.toc` | Folder name (`Chatter-Companion-master`) does not match `Chatter.toc` | Rename folder to `Chatter`, **or** open it and move the inner files up one level |
| `Interface\AddOns\Chatter-Companion-master\Chatter\Chatter.toc` | The real `Chatter` folder is one level too deep | Move the inner `Chatter` folder up into `Interface\AddOns\` |
| `Interface\AddOns\Chatter\Chatter\Chatter.toc` | Doubled-up `Chatter\Chatter\` from a re-extracted ZIP | Move the inner files up one level so `Chatter.toc` sits directly under `AddOns\Chatter\` |
| Folder placed in `World of Warcraft\AddOns\` | Wrong path — addons live under `Interface\` | Move to `Interface\AddOns\` |

### 3. Enable the addon in WoW

1. Fully quit WoW (don't just `/reload` — a full restart is the safest first time).
2. Launch the game and stop at the character select screen.
3. Click the **AddOns** button in the bottom-left.
4. Make sure `Chatter` is in the list and its checkbox is **enabled**.
5. **Tick "Load out of date AddOns"** — the `.toc` is tagged `Interface: 30300`, which is correct for 3.3.5a, but some clients still flag it.
6. Log into your character.

### 4. Verify the addon loaded

In-game, type:

```
/chatter
```

The Chatter Companion window should open. If it doesn't, see Troubleshooting below.

---

## Usage

- Open the addon with `/chatter` or `/llmc`
- Search the scrollable Known Bots list, then click a name to edit it
- Edit the three traits
- Click `Save Traits`
- The server regenerates the tone from the saved traits
- The addon refreshes and displays the generated tone

Tone is generated by the backend and shown in the UI as read-only output.

### If a save does not go through

Saving is not finished when the addon stops sending; it is finished when
the server says it applied the traits. Until that confirmation arrives the
editor stays locked and the traits you typed remain the only copy, so a
server that rejects the save or never answers cannot quietly roll the boxes
back to the old values. In either case the editor unlocks with your text
still in it and a message explaining what happened, and you can correct the
traits and save again.

### Managing known bots

The `/chatter` floating window shows traits, tone and background story
together. The bot list scrolls independently of the profile.

Interface Options > AddOns > Chatter has two dedicated sections:

- **Bot Traits**: edit the three traits, view tone and manage known bots.
- **Background Stories**: select a bot, read its scrollable story and use
  **Regenerate Story** at the bottom.

Both sections share the selected bot. Switching sections preserves unsaved
trait edits. The Chatter overview has an **Open full editor** button that
closes Interface Options and opens the floating editor with the same bot
and edits.

Check the boxes beside several bot names, then click **Forget selected**.
**Check all** checks every bot matching the current search, including those
outside the visible portion of the list. **Clear** unchecks all bots,
including any hidden by a search. The checked count includes hidden checks.
Clicking a name opens its profile without changing the checked bots.

The confirmation lists the target count and names (summarized for large
selections). Forgetting erases those bots' memories with your character;
their global personalities remain intact. Requests are paced and wait for
server acknowledgement. An error or timeout stops the remaining batch.
Refresh the roster before retrying; already acknowledged bots are removed.

### Addon files and updates

Keep `Chatter.lua`, `ChatterRoster.lua`, and `ChatterUI.lua` alongside
`Chatter.toc`. The manifest loads all three. No Ace3 or other addon is
required. After updating, restart the client if it has not discovered the
new Lua files; otherwise `/reload` reloads the addon.

After an update, check `/chatter` and both Interface Options sections,
**Bot Traits** and **Background Stories**. Verify scrolling with a long
roster in each, a long story in the full editor and in Background Stories,
search, checkbox selection, and saving from either trait editor. Only
confirm Forget on bots whose shared memories you intend to erase.

### Tests

`tests/` holds regression coverage for the save lifecycle — rejection,
timeout, interruption, and switching bots mid-save — run against a stubbed
client rather than in game. It is developer tooling, not part of the addon:
`Chatter.toc` does not reference it and the client never loads it.

```
lua5.1 tests/run_tests.lua
```

Lua 5.1 is the version the 3.3.5 client runs. Without it installed:

```
docker run --rm -v "$PWD":/addon -w /addon \
  nickblah/lua:5.1-alpine lua tests/run_tests.lua
```

---

## Troubleshooting

**"Chatter does not appear in the AddOns menu"**
- Almost always a folder-layout problem — re-check the table in [Installation step 2](#2-place-the-folder-correctly).
- Confirm `Chatter.toc` is at `Interface\AddOns\Chatter\Chatter.toc` exactly.
- Fully restart the WoW client (not just `/reload`).

**"Chatter window opens but the bot roster is empty"**
- This is expected on first use. Bots appear only after you have grouped with them and the server has stored their chatter identity.
- Group up with a playerbot, run any content for a minute, then `/reload` and reopen `/chatter`.
- If it stays empty across multiple sessions, the server-side `mod-llm-chatter` module is probably not running. Check that the Python bridge is up and that `LLMChatter.Enable = 1` in `mod_llm_chatter.conf`.

**"Saving traits seems to do nothing"**
- The save path goes through the server. If `mod-llm-chatter` is not installed or the bridge is offline, the addon has nothing to talk to.
- On the server, confirm `ac-llm-chatter-bridge` (Docker) or your `llm_chatter_bridge.py` process is running and connected to the database.

**"`/chatter` says unknown command"**
- The addon is not loaded. Re-check Installation step 3, especially the **Load out of date AddOns** checkbox.

---

## Notes

- `ChatterDB` stores the window position and last selected bot per character.
  Traits and memories are stored by the server.
- The addon never invents data on its own — every bot, trait, and tone you see came from the server.
