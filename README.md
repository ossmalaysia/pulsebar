# PulseBar

A tiny macOS menu-bar app and floating desktop widget that shows **available memory** and **CPU
utilization**, records **30 days of history**, and can send **WhatsApp alerts through
[EzyChat](https://github.com/ossmalaysia/ezychat-lite)'s MCP server** when your Mac runs low on memory
or stays busy for too long.

Native Swift/AppKit + SwiftUI Charts, three source files, no dependencies, no Xcode project.

<p>
  <img src="docs/widget.png" width="220" alt="Floating widget with memory and CPU cards">
  <img src="docs/history-memory.png" width="560" alt="Memory history, 7 days">
</p>

## Features

- **Menu bar**: available memory and CPU %, e.g. `21.5 GB · 10%`. Turns red when memory is low or CPU is pegged.
- **Floating widget**: two cards (memory, CPU) that stay on top on every Space. Drag to move.
  Click a card to open its history. Right-click opens the menu.
- **History**: one sample per minute (average and peak), kept for 30 days. Charts for 24 hours, 7 days and 30 days,
  with average and peak values, time above 80% CPU, and so on.
- **Alerts over WhatsApp (optional)**: when available memory stays below *X GB* or CPU stays above *Y %*
  for *N* minutes. Includes the top processes, a cooldown, and a "back to normal" message.

Memory is computed the way Activity Monitor does: *used = app memory + wired + compressed*, so
*available = total − used*. CPU % is the change in host CPU ticks across all cores.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`

## Build and run

```sh
git clone https://github.com/ossmalaysia/pulsebar.git
cd pulsebar
./build.sh            # builds PulseBar.app here
open PulseBar.app
./build.sh --install  # optional: copies to /Applications
```

To start it at login, add PulseBar under **System Settings → General → Login Items**.

## Using it

| Do this | To |
|---|---|
| Click the menu-bar item | Show/hide widget, Memory History (⌘H), CPU History (⌘J), **Settings… (⌘,)**, Record History, Quit |
| Right-click the widget | Open the same menu |
| Click a card | Open that card's history |
| Drag a card | Move the widget (the position is remembered) |

## WhatsApp alerts via EzyChat

PulseBar signs in to EzyChat's built-in MCP server (`/mcp`) with **OAuth**, the same way claude.ai
connects to it. You never copy a token. After that, PulseBar sends each alert with one JSON-RPC
`tools/call` request to `send_message`. Claude or any other AI client doesn't need to be running.

### Before you start

- You can sign in to EzyChat as an **admin**.
- EzyChat is reachable from this Mac: on the same computer (`localhost:<port>`), or through its public or
  tunnel address (`https://…`).
- Your own WhatsApp number has a chat in the inbox. EzyChat only sends into chats that already exist, so if
  you've never messaged your EzyChat number, send it any message from your phone first.

### Setup (about 2 minutes)

| # | Where | Do this |
|---|---|---|
| 1 | EzyChat → **Admin → Settings → Integrations** | Turn on **Let AI assistants read this inbox**. |
| 2 | PulseBar menu → **Settings… (⌘,)** | Under **EzyChat**, enter the address (e.g. `https://<your-ezychat>` or `localhost:<port>`) and click **Connect EzyChat…**. |
| 3 | Browser | EzyChat opens. Sign in as an admin and click **Approve**. You're sent back to PulseBar, which shows **Connected**. |
| 4 | EzyChat → **Integrations → Connected apps** | New apps can only read. Turn on **Can send WhatsApp messages** for **PulseBar**. |
| 5 | PulseBar Settings | Click **Check Again**. **Sending** should change to **Allowed**. |
| 6 | PulseBar Settings | Enter your WhatsApp number with the country code (e.g. `60123456789`). If EzyChat has more than one WhatsApp number, choose the one alerts come from under **Send from**. |
| 7 | PulseBar Settings | Click **Send Test Message**. You should get a WhatsApp message within a few seconds. |
| 8 | PulseBar Settings | Set the thresholds under **When to alert**, then turn on **Send WhatsApp alerts through EzyChat** at the top. |

The first time PulseBar reads its saved access (and again after you rebuild it), macOS may ask
*"PulseBar wants to use your confidential information stored in … keychain"*. Enter your Mac login password
and click **Always Allow**.

<p>
  <img src="docs/settings-connect.png" width="380" alt="Settings: connect EzyChat">
  <img src="docs/settings-connected.png" width="380" alt="Settings: connected, sending permission">
</p>

### Troubleshooting

Every message PulseBar sends, or fails to send, is listed under **Recent alerts** in Settings.

| PulseBar says | What to do |
|---|---|
| *AI assistant access is off in EzyChat* | Do step 1. EzyChat hides every MCP and sign-in address while this is off. |
| *Sending is off for PulseBar* | Do step 4, then click **Check Again**. |
| *Your number has a chat in more than one EzyChat inbox* | Choose a number under **Send from** (step 6). EzyChat won't guess which WhatsApp number to send from. |
| *No chat found for …* | Your number has no chat in that inbox. Message the EzyChat number from your phone once, or pick the other inbox under **Send from**. |
| *EzyChat no longer accepts PulseBar's access* | PulseBar was removed in **Connected apps**, or the admin who approved it changed. Click **Connect EzyChat…** again. |
| *The connection was denied in EzyChat* | **Deny** was clicked on the approval page. Connect again and click **Approve**. |
| The browser page says the address can't be reached | Check the address. EzyChat only accepts sign-in on the same computer or through its tunnel address, not by LAN IP. |
| Test works but no alerts arrive | Check that the switch at the top of Settings is on and the thresholds are reachable. Alerts need the limit to be crossed on average for the whole window (default 5 min). |

To disconnect, click **Disconnect** in PulseBar. To revoke the access completely, also remove PulseBar in
EzyChat → **Connected apps**.

### Under the hood

How the sign-in works (the [MCP authorization](https://modelcontextprotocol.io/specification/draft/basic/authorization) flow):

- **Discovery**: `/.well-known/oauth-protected-resource/mcp` points to the authorization server metadata.
- **Registration**: PulseBar registers itself as a public client (RFC 7591). It has no client secret.
- **Approval**: the browser opens the approval page with **PKCE S256**. EzyChat sends the browser back to a
  one-time loopback address, `http://127.0.0.1:<random port>/callback` (RFC 8252). PulseBar listens there
  only during sign-in.
- **Token**: the one-time code and PKCE verifier are exchanged for an app token, which is stored in the
  **macOS Keychain**. EzyChat issues no refresh token. Access lasts until you remove PulseBar under
  **Connected apps**, or click **Disconnect** in PulseBar. If EzyChat stops accepting the token,
  PulseBar shows "Connect" again.
- EzyChat accepts sign-in only on the same computer or through its tunnel address.

How alerts behave:

- They trigger on the **average over the window** (default 5 min), not on single spikes.
- One alert per condition, then a **cooldown** (default 30 min).
- "Back to normal" is only sent after an alert was actually delivered, and only once the value is clearly
  past the limit (memory ≥ limit + 1 GB, CPU ≤ limit − 10 points), so a value sitting near the line doesn't flap.
- If sending fails (bad token, server unreachable), PulseBar retries after 5 min. Every attempt is shown
  under **Recent alerts**.

How the chat is picked: with one WhatsApp number, PulseBar passes your phone number and EzyChat finds its
chat. With several, it addresses the chat in the chosen inbox directly: `<phone>@s.whatsapp.net` for inbox 1,
`<phone>@s.whatsapp.net#<inboxId>` for the others. The list of numbers comes from `get_stats` (`byInbox`).

## Privacy

- History and the alert log stay on your Mac in `~/Library/Application Support/PulseBar/`
  (`history.csv`, `alerts.log`).
- The EzyChat access from OAuth sign-in is stored in the **macOS Keychain**, not in preferences or files.
- The only thing sent anywhere is the alert text, which goes to your own EzyChat server. It includes the
  computer name and the names of the top 3 processes.

## Development

```
main.swift      app delegate, menu bar, floating widget, memory/CPU sampling
history.swift   per-minute recorder, CSV store, history window (Swift Charts)
alerts.swift    alert engine, EzyChat MCP client, Keychain, settings window
oauth.swift     EzyChat OAuth sign-in: discovery, client registration, PKCE, loopback redirect
build.sh        swiftc build + .app bundle (ad-hoc signed)
```

Self-tests (no Accessibility permission needed):

```sh
# Widget drag vs click handling
./PulseBar.app/Contents/MacOS/PulseBar --selftest

# Alert engine: simulates ~40 minutes of samples against a mock EzyChat MCP server
python3 scripts/mock_ezychat_mcp.py 8765 /tmp/sent.jsonl &
PULSEBAR_HISTORY=/tmp/pb-history.csv PULSEBAR_MCP_URL=http://127.0.0.1:8765/mcp \
PULSEBAR_TOKEN=ezc_pat_testtoken123 ./PulseBar.app/Contents/MacOS/PulseBar --alerttest

# OAuth sign-in end to end (the authorize page is fetched headlessly instead of opening a browser)
python3 scripts/mock_ezychat_mcp.py 8770 /tmp/sent.jsonl --grant-send &   # also try --deny, --mcp-off, --inboxes
PULSEBAR_TOKEN=unused PULSEBAR_EZYCHAT_ADDRESS=127.0.0.1:8770 ./PulseBar.app/Contents/MacOS/PulseBar --oauthtest
```

`PULSEBAR_TOKEN` puts the app in test mode: it never reads or writes the real Keychain or EzyChat settings.
`PULSEBAR_HISTORY` redirects the data files, so tests don't touch your real history.
`--show-history` and `--show-settings` open those windows at launch.

## License

[MIT](LICENSE)
