# YouTube Music for the Omarchy bar

A bar widget for [Omarchy](https://omarchy.org) 4 that turns the YouTube Music desktop app
([pear-desktop](https://github.com/pear-devs/pear-desktop)) into a full remote. The app runs
hidden in the background, starts when you need it, and quits when you don't.

- **Bar:** a small equalizer and the song title. Left click opens the panel, right click plays
  or pauses, middle click skips, and the scroll wheel skips too (up for the previous song, down
  for the next; one skip per notch or trackpad flick, and only while a song is loaded). While the
  app is closed it shows the last song, dimmed, and it pulses while the app starts.
- **Panel:** cover, seek bar, shuffle, previous, play, next, repeat, like, dislike, volume,
  Up next, search, Home, Library (playlists, liked songs, albums, artists, recent), Queue and
  Lyrics. The icon buttons have tooltips. With nothing loaded, play starts Liked songs.
  - Home and the Library pages are kept for 10 minutes, so they show at once when you come
    back; after that they still show at once and refresh quietly behind the scenes.
  - When a list fails to load, a Try again button reloads it.
  - Albums, playlists, artists and podcasts open in place. Back (or Esc) returns to the same
    list at the same spot.
  - Long lists load as you scroll. Artist shelves have a "Show all" link.
  - Search keeps YouTube Music's order and has filters (All, Songs, Albums, Artists,
    Playlists).
  - The Queue tab opens on the playing song and jumps to or removes songs by their queue id,
    so a quick second click never hits the wrong row.
  - Keys: `/` searches, Enter opens the top result, Up and Down (or j and k) pick a row, Left
    and Right (or h and l) seek 10 seconds, Space plays or pauses, Esc steps back, Tab moves to
    the next bar panel.
  - Clicking the cover shows or hides the app window.
- **Lyrics, the Apple Music way:** big bold lines, the sung line bright, the rest faded and
  softly blurred, the list gliding to keep the sung line a third of the way down, dots that fill
  during instrumental breaks, tap a line to jump there. When the song has word timing, each
  word fills in as it is sung.
- **Lifecycle:** the app starts in the background when you press play, or when the panel stays
  open for 400 ms. Its window lives on a hidden `special:music` workspace. After `idleMinutes`
  (5, at least 1) paused, with the panel closed and the app window out of sight, it quits
  cleanly; on battery it quits after 2 minutes (or `idleMinutes`, when that is shorter).
- **Messages:** what the widget has to tell you (the app isn't set up, a song is gone, the app
  didn't start) shows in the panel when it is open, and as a desktop notification when it is
  not.
- **Resume:** play picks up the last song at the second you left it, even after the app was
  closed. With nothing remembered, play starts Liked songs.

## Setup

1. **Add the plugin:**

   ```bash
   omarchy plugin add https://github.com/nicolasfalesy/omarchy-youtube-music.git --enable
   ```

2. **Open the panel** (click the widget in the bar). It walks you through the rest:

   - **If the YouTube Music app isn't installed**, it shows an **Install** button. That opens a
     terminal running `yay -S --needed pear-desktop-bin`, where yay asks you to confirm. The
     panel moves on by itself when the install finishes.
   - **Then a Set up button**, with a short note on what it changes. Nothing is changed until
     you click it. It takes a few seconds and runs `tools/setup` (below).
   - **Sign in** inside the app if it asks: click the cover in the panel to show the app window.

If the app ever turns the widget's key down (its settings were reset, for example), the panel
says "Run Set up again" and offers the same button.

That's all. The widget keeps the app's window on a hidden `special:music` workspace by itself:
it adds a runtime Hyprland window rule named `nic-youtube-music` (with `hyprctl eval`, so no
config file is edited), and adds it again after a config reload.

### What Set up does

It runs `~/.config/omarchy/plugins/nic.youtube-music/tools/setup`, which you can also run
yourself from a terminal (safe to run again). On a first run it starts the app once so the app
creates its settings. It turns on the app's API server (local only, `127.0.0.1`) and **locks it
to this widget**: it mints a token only the widget holds (saved mode 600 in
`~/.local/state/omarchy/nic-youtube-music/token`) and switches the app to `AUTH_AT_FIRST`, so
any other program, or a web page, is refused. It also adds a menu entry that starts the app
through `tools/cdp-bridge` (see below), removes any old `--remote-debugging-port` line from
`~/.config/youtube-music-flags.conf` (or `~/.config/pear-flags.conf` for the source package), and turns off the app's `resumeOnStart`, tray,
start-at-login and its own updater (the widget does the resuming and quits the app when idle;
the package manager updates the app). If the app's API ever answers without the token again,
the panel says so and offers Set up. Setup only reports the API locked after checking that the
app has quit and nothing answers without the token; if the app will not quit, it says the API
is still open, names the process to close, and stops with an error.

## Settings

Set these on the widget's bar entry in `~/.config/omarchy/shell.json`, for example
`{ "id": "nic.youtube-music", "showTitle": false }`:

- `showTitle` (default `true`): the song title next to the equalizer. `false` shows the icon
  alone.
- `maxLabelWidth` (default `150`): how wide the title may get on the bar, in pixels, before it
  is cut off with an ellipsis.
- `idleMinutes` (default `5`, at least `1`): how long the app may sit paused and out of sight
  before it quits. On battery it is 2 minutes, or this value when that is shorter.

### How the widget reaches the app, and why no port is open

The widget needs the app's DevTools protocol to read your library, playlists, the queue and the
real play state (the app's own API cannot). The usual way to get it,
`--remote-debugging-port`, opens an unauthenticated port that gives every local program and user
full control of the signed-in app, cookies included. So this plugin never uses a port.
`tools/cdp-bridge` starts the app with Chromium's `--remote-debugging-pipe`: the protocol runs
over two file descriptors that only the bridge holds, and the bridge passes it to the widget on
a Unix socket in `$XDG_RUNTIME_DIR/nic-youtube-music/` (folder 0700, socket 0600, and each
connection's user is checked). The widget starts the app through the bridge, and so does the
menu entry Set up adds.

The widget sends its token to the app's API port only once that port is known to belong to
you: while the app is closed it asks without the token, and when something answers there it
checks with `ss` that the listening program is yours before the token goes out.

If the app is started some other way (for example `youtube-music` from a terminal), it runs
without the pipe: playback controls still work over the API, but the library, search, queue and
lyrics timing do not until it is quit and started again from the widget or the menu.

## Dependencies

- Omarchy 4 (the Quickshell `omarchy-shell` and Lua Hyprland config).
- [pear-desktop](https://github.com/pear-devs/pear-desktop): either `pear-desktop-bin` from the AUR (upstream's build, with its own Electron) or `pear-desktop` (built from source on Arch's `electron42`, so Electron security fixes arrive with system updates),
  signed in to a YouTube Music account.
- `python3` for `tools/cdp-bridge`, and `jq`, `curl` and `openssl` for `tools/setup` and
  `tools/lock-api`; `ss` (iproute2) to check who owns the API port, and `notify-send`
  (libnotify) for messages while the panel is closed. Omarchy ships all of them.

## Remove

```bash
omarchy plugin remove nic.youtube-music
rm -rf ~/.local/state/omarchy/nic-youtube-music
rm -f ~/.local/share/applications/com.github.th-ch.youtube-music.desktop
# Left by an early version, if the widget has not run since:
rm -f ~/.local/state/omarchy/nic-youtube-music-last.json
```

With the app closed, turn its API server off in `~/.config/YouTube Music/config.json` (or leave
it on: it stays locked to a token nothing holds any more). The window rule the widget added
goes away at the next Hyprland reload or login; to drop it at once:

```bash
hyprctl eval 'hl.window_rule({ name = "nic-youtube-music", enabled = false, match = { class = "com.github.th-ch.youtube-music" } })'
```

If you added an `o.window(...)` line for this app to `~/.config/hypr/hyprland.lua` with an older
version of this plugin, you can remove it (it does no harm either way).

## What it sends where

- The app: its API on `127.0.0.1:26538` (token-locked), and the DevTools protocol over the
  private socket described above. No debug port.
- Cover art and thumbnails: the bar loads them itself, straight from Google's image hosts
  (`lh3`-`lh6.googleusercontent.com`, `yt3`/`yt4.ggpht.com`, `yt3.googleusercontent.com`,
  `i.ytimg.com` and `i1`-`i3.ytimg.com`, `www.gstatic.com`), over https only. Any other image
  address is not loaded.
- Lyrics, only while the Lyrics tab is open: the song's title, first artist and length go to
  [LRCLIB](https://lrclib.net) (plus the album) and to KuGou (`krcs.kugou.com`,
  `lyrics.kugou.com`), which has the word timing. Without either, YouTube Music's own lyrics
  show.

## IPC

`omarchy-shell nic.youtube-music <name>`, where name is one of `status`, `open`, `close`,
`toggle`, `playPause`, `pause` (pauses, never starts or wakes anything), `next`, `previous`,
`wake`, `quit`, `search <q>`,
`tab home|library|queue|lyrics`, `library <browseId>`, `openRow <n>`, `playRow <n>`, `back`,
`filter <label>`, `cursor <n>`, `scrollList <px>` and `scrollUpNext <px>`.

If the `nic.world-radio` plugin is installed too, starting either one stops the other.

## Tests

- `tests/qml/run` tests the widget: the real `Widget.qml`, loaded by `qmltestrunner` against
  stand-ins for Quickshell and the Omarchy shell (`tests/qml/stubs`), in its own network
  namespace, with nothing drawn on screen and nothing of yours read or written. Any QML warning
  from the widget's own files fails it. `tests/qml/run --quick` runs each test once (under a
  minute); without `--quick` it also loads the widget in 20 fresh processes. Needs
  `qt6-declarative` (for `qmltestrunner`), `python3` and unprivileged user namespaces.
- `tests/run` tests the tools (`cdp-bridge`, `setup`, `lock-api`) against a stand-in app;
  `tests/run --quick` runs the fast part.

### Manual checks

What the tests cannot reach, to try by hand after a change:

1. Scroll on the bar widget while a song plays: one notch or one trackpad flick skips once.
2. Close the panel, then right-click the bar widget with the app not set up: a desktop
   notification says so.
3. Open the panel on a second monitor's bar: the panel there works the same.

## Notes for hacking on it

- Quit the app with the `quit` IPC (Browser.close through the bridge). A plain kill makes
  Chromium crash on purpose and shows a crash notice.
- `tools/cdp-bridge` is the app's parent and the only holder of its debugging pipe. The socket
  speaks one JSON message per line (the pipe itself separates them with a NUL byte), and the
  connection is browser-level: the widget attaches to the YouTube Music page with
  `Target.attachToTarget` (flatten) and sends page commands with that `sessionId`.
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
