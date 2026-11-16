<p align="center"><img src="docs/icon.png" width="128" alt="Spatial icon: a diamond of dots, shrinking from the middle out"></p>

<h1 align="center">Spatial</h1>

<p align="center"><b>Spatial Audio for Spotify on the Mac.</b><br>
Fixed and Head Tracked from Control Center, rendered by macOS itself.</p>

<p align="center"><a href="https://github.com/matthewhamilton3141/spatial/releases/latest/download/Spatial.zip"><b>Download Spatial</b></a> · free · open source</p>

---

Spotify's Mac app doesn't get Spatial Audio. Play something and open the AirPods menu in
Control Center: Spatial Audio is unavailable. Spatial is a small menu bar app that fixes
that. Once it's running, Control Center offers **Off / Fixed / Head Tracked** for Spotify,
and macOS renders it with the same engine it uses for its own apps, including your
Personalized Spatial Audio profile if you've set one up.

## Requirements

- A Mac with Apple silicon, macOS 15 or later (built and tested on macOS 26)
- AirPods or Beats that support Spatial Audio
- The Spotify desktop app

## Install

1. [Download Spatial.zip](https://github.com/matthewhamilton3141/spatial/releases/latest/download/Spatial.zip), unzip it, and drag **Spatial** into Applications.
2. Open it. Spatial isn't notarized by Apple yet, so macOS blocks the first launch. Go to
   **System Settings › Privacy & Security**, scroll down, and click **Open Anyway**.
   (Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Spatial.app`.)
3. Play something in Spotify. When macOS asks, allow **System Audio Recording**. That's how
   Spatial takes Spotify's sound. Nothing is recorded, saved, or sent anywhere.
4. Open **Control Center › your AirPods › Spatial Audio** and pick **Fixed** or **Head Tracked**.

Spatial lives in the menu bar (the dotted diamond). Turn off **Reroute Spotify** or quit Spatial,
and Spotify plays exactly as before.

## Good to know

**Head Tracked crackles?** Head tracking makes your Mac send about 50% more Bluetooth
packets to your AirPods. In a crowded 2.4 GHz area (dorms, offices, apartments) the link
can't keep up and you hear static. **Fixed** sounds the same, minus the head tracking,
and avoids it. This is Bluetooth, not Spatial: the audio Spatial hands to macOS is clean.

**Delay.** Pause and skip land about 0.15 s later than in plain Spotify. When you press play,
Spatial waits for your AirPods to wake up before it starts, so the music never has to skip
to catch up.

**Lossless?** AirPods always receive AAC over Bluetooth, with or without Spatial. Spatial
adds no loss of its own: with Spatial Audio set to Off, what it plays matches Spotify to
within -100 dB.

**The recording indicator.** macOS may show its recording indicator while Spatial runs,
because taking another app's sound uses the same permission as recording it.

**Other apps.** `defaults write local.spatial target <bundle id prefix>`, then relaunch Spatial.

## How it works

1. A Core Audio **process tap** (macOS 14.2+) takes Spotify's output and mutes it at the speakers.
2. Spatial plays the exact same samples through `AVSampleBufferAudioRenderer` with stereo
   spatialization allowed, so macOS treats it as a spatial-capable app.
3. Control Center's Spatial Audio menu now applies to it, and macOS does the rendering:
   it upmixes the stereo, places it with your HRTF, and runs head tracking from your AirPods.

Spatial does no processing of its own in this mode. It keeps about 0.3 s of audio queued
(the AirPods' Bluetooth latency plus headroom for clock jitter) and handles the renderer
reconfiguring itself when you switch modes.

The **Engine** menu also has two renderers of Spatial's own, for experimenting:
**Apple Spatial Mixer** (`AUSpatialMixer`, the renderer behind Spatialize Stereo, driven
directly) and **Virtual Speakers** (`AVAudioEnvironmentNode`, two HRTF sources at ±30°,
optional room). Both support head tracking but skip the Control Center menu.

## Build from source

Needs only the Command Line Tools (no Xcode).

```sh
./build.sh run                     # build build/Spatial.app and open it
./build.sh release                 # same, plus build/Spatial.zip for a GitHub release
.build/release/Spatial --smoke     # headless self-test: engines, ring, system player
.build/release/Spatial --probe     # audio processes and the output device
open build/Spatial.app --stderr /tmp/spatial.log --args --log   # live state, once a second
```

The icon and menu bar glyph are drawn in code (`Sources/SpatialApp/Icon.swift`).

## License

MIT. Not affiliated with Spotify or Apple.
