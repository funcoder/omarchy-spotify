# Spotify for Omarchy

A keyboard-driven Spotify player that lives in the Omarchy shell and wears your
theme.

- **Now playing stage.** The album sleeve with a record that slides out and spins
  at 33⅓ rpm. It eases to a stop on pause and swaps discs when the track changes.
  Behind it is a soft glow that breathes with the music.
- **Omarchified artwork.** A shader maps every cover onto your theme: shadows go
  to the darkest background, highlights to the accent. The selected row shows
  the true colours. Press `o` to switch between omarchified and original art.
- **Live visualizer.** Spectrum bars from [cava](https://github.com/karlstav/cava)
  under the player, in the row that's playing, and in the bar widget.
- **Playlists with what's playing pinned on top.** Press `c` to jump into it.
  There are also tabs for Liked songs, Recent, Queue, Search and Devices
  (Spotify Connect).

## Requirements

- Spotify Premium.
- `spotifyd` to play audio on this computer, and `cava` for the visualizer:
  `sudo pacman -S spotifyd cava`. Without spotifyd you can still control a
  phone or speaker.

## Install

```sh
git clone <this repo> ~/.config/omarchy/plugins/funcoder.spotify
omarchy-shell shell rescanPlugins
omarchy plugin enable funcoder.spotify
```

Bind a key in `~/.config/hypr/bindings.lua`:

```lua
hl.unbind("SUPER + SHIFT + M")
o.bind("SUPER + SHIFT + M", "Spotify", "omarchy-shell shell toggle funcoder.spotify '{}'")
```

## Setup

Spotify only lets personal players use its API through an app you register:

1. Go to <https://developer.spotify.com/dashboard> and create an app. Tick **Web
   API** and add the redirect URI `http://127.0.0.1:8989/callback`.
2. Open the player and paste the app's **Client ID**, then log in. The refresh
   token is kept in your desktop keyring.
3. Press `d` for Devices, then Enter on **This computer**. This logs spotifyd in
   once (in your browser) and starts it as the `funcoder-spotifyd` user service.

## Keys

| Key | Action |
| --- | --- |
| `↑↓` / `j k` | Move |
| `Enter` | Play a song, open a playlist or album |
| `Shift+Enter` | Play a playlist or album without opening it |
| `Esc` / `Backspace` | Back, then close |
| `Tab` / `1`–`6` | Switch tabs |
| `/` | Search |
| `Space` | Play or pause |
| `← →` | Seek 10 s (`Shift` for 30 s) |
| `n` / `p` | Next or previous song |
| `+` / `-` / `m` | Volume up, volume down, mute |
| `s` / `r` | Shuffle, cycle repeat |
| `l` / `Shift+L` | Like the playing song, or the selected song |
| `a` | Add the selected song to the queue |
| `c` | Open the playlist or album that's playing |
| `o` | Switch between omarchified and original artwork |
| `d` | Devices |

Bar widget: click to open, right click to play or pause, middle click for the
next song, scroll to change the volume.

IPC target for your own bindings: `omarchy-shell funcoder.spotify.player playPause|next|previous|volumeUp|volumeDown|like|status`.

## Limits

Spotify's development-mode API only lists the songs of playlists you **own or
collaborate on**. Followed playlists still play, and once one is playing the
Queue tab shows what's coming up. Search returns 10 results per type.

## Development

`spotify.py <op> '<json>'` runs one helper request from a terminal. Set
`"demo": true` in `~/.config/funcoder-spotify/config.json` to try the UI with
fake data (`tools/demo.py`). After editing QML, restart the shell with
`omarchy restart shell`, because the plugin is `keepLoaded`.
