# Music EQ

A small, audio-reactive equalizer for the [Omarchy](https://omarchy.org/) bar:
4 bars driven by [cava](https://github.com/karlstav/cava), tinted in four shades
of the theme's accent colour, plus a scrolling now-playing text. Works with any
MPRIS player (Spotify, browsers, mpv, VLC, cliamp, …) via `playerctl`.

Left click opens a small player card with album art and previous / play-pause / next.

## Install

```sh
omarchy pkg add cava playerctl
omarchy plugin add https://github.com/taiku666/omarchy-music-eq.git --enable
```

Update with `omarchy plugin update io.github.taiku666.music-eq && omarchy restart shell`.
Remove with `omarchy plugin remove io.github.taiku666.music-eq`.

## Usage

| Action | Result |
|---|---|
| Hover | Title · artist tooltip |
| Left click | Player card (art, title, artist, previous / play-pause / next) |
| Middle click | Play / pause |
| Right click | Next track |
| Scroll up / down | Previous / next track |

- Playing: bars move with the music, the title scrolls if it is longer than the label.
- Paused or nothing playing: bars rest flat and dimmed, the text is hidden so the
  widget shrinks to just the bars.

Move it with:

```sh
omarchy bar move io.github.taiku666.music-eq --section right
```

## Configure

There are no settings in `shell.json` yet. Bar behaviour is tuned in the bundled
[`cava.conf`](cava.conf):

| Key | Value | Meaning |
|---|---|---|
| `bars` | `4` | Number of bars (the widget reads exactly 4) |
| `framerate` | `30` | Updates per second |
| `autosens` / `sensitivity` | `0` / `15` | Fixed gain, so the bars don't sit at maximum all the time |
| `monstercat` / `noise_reduction` | `1` / `0.77` | Smoothing |

Values below 14 (of 100) are clamped to 0 in the widget (`noiseGate` in
`BarWidget.qml`) so quiet passages rest flat instead of jittering.

## How it works

- **Track info / controls:** a long-running `playerctl --follow metadata` process
  pushes a line on every status or track change (no polling). Controls call
  `playerctl play-pause | next | previous`.
- **Bars:** a `cava` process reads the default audio output (PulseAudio/PipeWire)
  and prints 4 levels per frame to stdout. It only runs while something is playing.

Omarchy's built-in media service is only available to the trusted bar itself, not to
third-party widgets, which is why this plugin talks to MPRIS directly.

## Requirements

Omarchy (Quattro or later), `cava`, `playerctl`, and a player that supports MPRIS.

## What runs, and as whom

Omarchy plugins run inside the shell process, unsandboxed, as your user. This one
runs only `playerctl` (read metadata, send play/pause/next/previous) and `cava`
(read the audio output). Album art is loaded from the URL the player reports.
Nothing is written to disk.

## Troubleshooting

- **Widget shows nothing:** check that your player is on D-Bus with
  `busctl --user list | grep mpris` and that `playerctl metadata` prints something.
- **Player isn't listed:** restart the player. Some players (e.g. `cliamp`) sometimes
  fail to register MPRIS at startup ("name already taken").
- **After editing the plugin:** run `omarchy restart shell`; hot-reload isn't reliable.

## Licence

MIT, see [LICENSE](LICENSE).
