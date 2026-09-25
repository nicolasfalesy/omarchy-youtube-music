# YouTube Music for the Omarchy bar

A bar widget for [Omarchy](https://omarchy.org) 4 that turns the YouTube Music desktop app
([pear-desktop](https://github.com/pear-devs/pear-desktop)) into a full remote. The app runs
hidden in the background, starts when you need it, and quits when you don't.

- **Bar:** a small equalizer and the song title. Left click opens the panel, right click plays
  or pauses, middle click skips. While the app is closed it shows the last song, dimmed, and it
  pulses while the app starts.
- **Panel:** cover, seek bar, shuffle, previous, play, next, repeat, like, dislike, volume,
  Up next, search, Home, Library (playlists, liked songs, albums, artists, recent), Queue and
  Lyrics. Every button has a tooltip.
  - Albums, playlists, artists and podcasts open in place. Back (or Esc) returns to the same
    list at the same spot.
  - Long lists load as you scroll. Artist shelves have a "Show all" link.
  - Search keeps YouTube Music's order and has filters (All, Songs, Albums, Artists,
    Playlists).
  - The Queue tab opens on the playing song and jumps to or removes songs by their queue id,
    so a quick second click never hits the wrong row.
  - Keys: `/` searches, Enter opens the top result, arrows (or j and k) pick a row, Space plays
    or pauses, Esc steps back, Tab moves to the next bar panel.
  - Clicking the cover shows or hides the app window.
- **Lyrics, the Apple Music way:** big bold lines, the sung line bright, the rest faded and
  softly blurred, the list gliding to keep the sung line a third of the way down, dots that fill
  during instrumental breaks, tap a line to jump there. When the song has word timing, each
  word fills in as it is sung.
- **Lifecycle:** the app starts in the background when you press play, or when the panel stays
  open for 400 ms. Its window lives on a hidden `special:music` workspace. After `idleMinutes`
  (5) paused, with the panel closed and the app window out of sight, it quits cleanly.
- **Resume:** play picks up the last song at the second you left it, even after the app was
  closed. With nothing remembered, play starts Liked songs.

## Setup

1. **Install the app** and sign in to your account once:

   ```bash
   yay -S pear-desktop-bin
   ```

2. **Turn on its API server, local only.** Quit the app first (it rewrites its config when it
   quits), then:

   ```bash
   cfg="$HOME/.config/YouTube Music/config.json"
   jq '.plugins["api-server"] = ((.plugins["api-server"] // {}) + {enabled: true, hostname: "127.0.0.1", port: 26538, authStrategy: "NONE", useHttps: false})
       | .options.resumeOnStart = false | .options.tray = false | .options.startAtLogin = false' \
     "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
   ```

   `resumeOnStart` off keeps the app from starting music by itself; the widget does the
   resuming.

3. **Open its debug port, local only.** The widget reads your library, playlists, queue and the
   real play state through it. Put this in `~/.config/youtube-music-flags.conf`:

   ```
   --remote-debugging-port=9223
   --remote-debugging-address=127.0.0.1
   ```

4. **Hide its window** on the music workspace. Add this to `~/.config/hypr/hyprland.lua`:

   ```lua
   o.window("com.github.th-ch.youtube-music", { workspace = "special:music silent" })
   ```

5. **Add the plugin:**

   ```bash
   omarchy plugin add https://github.com/nicolasfalesy/omarchy-youtube-music.git --enable
   ```

6. **Optional, recommended: lock the API to the widget.** With `authStrategy` `NONE`, any local
   program or web page can drive the app's API. `tools/lock-api` mints a token for the widget
   (saved mode 600 in `~/.local/state/omarchy/nic-youtube-music/token`) and switches the app to
   `AUTH_AT_FIRST`, so anything else gets refused:

   ```bash
   ~/.config/omarchy/plugins/nic.youtube-music/tools/lock-api
   ```

## Dependencies

- Omarchy 4 (the Quickshell `omarchy-shell` and Lua Hyprland config).
- [pear-desktop](https://github.com/pear-devs/pear-desktop) (`pear-desktop-bin` from the AUR),
  signed in to a YouTube Music account.
- `jq`, `curl` and `openssl`, only for `tools/lock-api` and the World Radio link (Omarchy ships
  all three).

## Remove

```bash
omarchy plugin remove nic.youtube-music
rm -rf ~/.local/state/omarchy/nic-youtube-music
```

Then undo the setup steps you no longer want: delete `~/.config/youtube-music-flags.conf`,
remove the `o.window(...)` line from `~/.config/hypr/hyprland.lua`, and turn the app's API
server off again (or set its `authStrategy` back to `NONE` if you ran `tools/lock-api`), with
the app closed.

## What it sends where

- The app: `127.0.0.1:26538` (API) and `127.0.0.1:9223` (debug port). Nothing else.
- Lyrics, only while the Lyrics tab is open: the song's title, first artist and length go to
  [LRCLIB](https://lrclib.net) (plus the album) and to KuGou (`krcs.kugou.com`,
  `lyrics.kugou.com`), which has the word timing. Without either, YouTube Music's own lyrics
  show.

The debug port gives full control of the app to any program on your machine, which is why it
is bound to `127.0.0.1`.

## IPC

`omarchy-shell nic.youtube-music <name>`, where name is one of `status`, `open`, `close`,
`toggle`, `playPause`, `next`, `previous`, `wake`, `quit`, `search <q>`,
`tab home|library|queue|lyrics`, `library <browseId>`, `openRow <n>`, `playRow <n>`, `back`,
`filter <label>`, `cursor <n>`, `scrollList <px>` and `scrollUpNext <px>`.

If the `nic.world-radio` plugin is installed too, starting either one stops the other.

## Notes for hacking on it

- Quit the app with the `quit` IPC (Browser.close over the debug port). A plain kill makes
  Chromium crash on purpose and shows a crash notice.
- `Page.js` is the code the widget runs inside the app's page. Keep it free of any work at load
  time: building its text at load time set off a Qt 6.11 garbage-collector crash at shell start.
  The why is at the top of the file.
- The app's own word on "playing" is not trusted: it marks every newly loaded song as playing,
  never reports a play or pause at 0:00, and restores the last queue as a cued song on every
  start. The comments at the top of `Widget.qml` explain how the widget copes.

## Credits

Built on Omarchy's Media bar widget (MIT, [basecamp/omarchy](https://github.com/basecamp/omarchy)).
Timed lyrics from [LRCLIB](https://lrclib.net) and KuGou; plain lyrics from YouTube Music.

MIT license, see [LICENSE](LICENSE).
