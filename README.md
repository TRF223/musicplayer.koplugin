# musicplayer.koplugin

Play music with [mplayer](https://www.mobileread.com/forums/attachment.php?s=5e65e3c224a8800105dabb8d70c08774&attachmentid=66277&d=1297101459) from inside [KOReader](https://github.com/koreader/koreader). Made for the **Kindle Keyboard (K3)**.

Tap a song in KOReader's normal file browser and it plays. Every audio file in that folder becomes the playlist, and it moves to the next song on its own. Music keeps playing while you read.

## Features

- Tap a song in the file browser to play it (no separate music library to set up)
- Playlist is built from the folder you tapped in; plays in alphabetical order
- Automatically continues to the next track
- Controls: previous, pause/play, next, seek ±30 seconds, shuffle, repeat, stop
- Keeps playing when you open or close a book
- Optional key and gesture bindings through KOReader's own settings
- Volume is handled by the Kindle's hardware volume buttons (no software volume)

Recognised formats: `mp3 ogg flac wav aac m4a opus wma ape mka` (what actually plays depends on what your mplayer build can decode).

## Requirements

| What | Details |
|---|---|
| Device | Kindle Keyboard (K3), jailbroken, running KOReader. Developed and tested on a K3. Other Kindles with the same setup may work but are untested. |
| KOReader | **v2024.01 or newer.** The file-open hook this plugin relies on was added in November 2023; older builds will not work. |
| mplayer | A build for your device's CPU (ARMv6 Linux on the K3) with **ALSA audio output** and **slave mode**. A static binary is easiest. A folder containing mplayer plus its libraries also works. This plugin does **not** include mplayer. |
| System tools | `sh`, `kill`, and `mkfifo` (or `mknod`). These come with the Kindle's BusyBox, so there is nothing to install. |
| Storage | A writable `/tmp` (present by default). Used for the control pipe and a log file. |

## Installation

1. Download the latest zip from the [Releases](../../releases) page, or clone this repo.
2. Copy the `musicplayer.koplugin` folder into KOReader's plugins folder, usually `/mnt/us/koreader/plugins/`.
3. Put mplayer somewhere on the Kindle, for example `/mnt/us/mplayer`.
4. Restart KOReader.

## Usage

1. Open a folder containing music in the KOReader file browser.
2. Tap a song.
3. **First time only:** it asks where mplayer is. Enter the path to the mplayer file, or to the folder that contains it (for example `/mnt/us/mplayer`). It checks the path before saving.
4. A control box appears. You can close it and the music keeps playing.

To bring the controls back or change settings: **Menu → More tools → Music Player**.

- Controls
- Play / pause, Next track, Previous track, Stop
- mplayer location… (change the path you entered at first run)

### Binding keys

The plugin adds three actions to KOReader: **Music: play/pause**, **Music: next track**, **Music: previous track**. Bind them to any key or gesture using KOReader's own gesture/shortcut settings, so you can skip songs while reading without opening a menu.

## Known limitations

- The playlist only includes audio files in the **same folder** as the song you tapped, not subfolders.
- No software volume control (use the Kindle's volume buttons).
- Use KOReader's **Classic** file browser display mode. The cover/mosaic modes try to read audio files as books.
- It does not remember the last track or position between KOReader restarts.
- Audio is played with `-ao alsa`. If your mplayer build uses a different audio driver, it will not produce sound.

## Troubleshooting

| Problem | What to try |
|---|---|
| Songs don't appear in the file browser | Make sure the plugin folder is in `koreader/plugins/`, restart KOReader, and check you are on KOReader v2024.01 or newer. |
| "Couldn't find mplayer at…" | Check the path. Give the exact file, or the folder that contains a file named `mplayer`. |
| "mplayer stopped right after starting" | Read `/tmp/mplayer_ko.log` for the real error. Usual causes: mplayer built for the wrong CPU, a missing library, or no ALSA support. |
| It starts but there's no sound | Raise the volume with the hardware buttons. Otherwise your mplayer build may lack ALSA output. |
| Songs appear in bold | That is KOReader marking files you haven't opened yet. Turn it off under the file browser **Settings → Classic mode settings → "Show new (not yet opened) files in bold"**. |

When reporting a bug, please include your KOReader version, which mplayer build you use, and the contents of `/tmp/mplayer_ko.log`.

## How it works

The plugin registers audio files with KOReader so they show up in the file browser and open with the plugin instead of the book reader. It starts mplayer in slave mode and sends it commands (pause, seek, quit) through a named pipe at `/tmp/mplayer_ko.fifo`. It checks every couple of seconds whether mplayer has finished the current track and then starts the next one. Settings are stored in KOReader's settings folder as `musicplayer.lua`.

## AI disclosure

The code and this README were written with **Claude**, an AI assistant made by [Anthropic](https://www.anthropic.com), through the claude.ai chat interface. I (the author) described what I wanted, uploaded the results, reported what broke, and tested every version on a real Kindle Keyboard. Claude wrote and revised the code in response.

What that means in practice:

- The first versions did not work on a real device. The current version was rewritten after checking KOReader's source code, and it works on my K3.
- Claude also ran its own tests, but only against a stand-in for KOReader and a fake mplayer, not on a real Kindle. Real-world results from other devices, KOReader versions, and mplayer builds are not guaranteed.
- Please read the code before trusting it with anything important. It is a single file, `main.lua`, and it runs shell commands to start and stop mplayer.

Bug reports and fixes are welcome.

## License

[MIT](LICENSE). Do whatever you like with it.

mplayer is a separate program under its own license and is not part of this project.
