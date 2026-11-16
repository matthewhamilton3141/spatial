# Spatial

Spatial audio for Spotify on the Mac. Spotify's desktop app isn't a "supported app" for
macOS's Spatialize Stereo, so Spatial takes Spotify's sound off the speakers with a muted
Core Audio process tap and plays it back through a spatial renderer to whatever you're
listening on.

Menu bar only. Needs macOS 15+ and the Command Line Tools.

```sh
./build.sh run              # build build/Spatial.app and open it
.build/release/Spatial --smoke   # headless self-test of both engines
.build/release/Spatial --probe   # audio processes + output device, no tap
open build/Spatial.app --stderr /tmp/spatial.log --args --log   # state + input level each second
```

**Hiding the icon:** the menu has *Hide Menu Bar Icon*. Spatial keeps running; open
Spatial again (Spotlight, Finder, or `open build/Spatial.app`) and the icon comes back.

**Icon:** a listener inside two broken rings of sound, drawn in code
(`Sources/SpatialApp/Icon.swift`) for both the menu bar glyph and the app icon;
`build.sh` turns it into `Spatial.icns` via `scripts/make-icon` and `iconutil`.
`.build/make-icon preview <dir>` writes look-at-it renders.

First launch asks for **System Audio Recording**. If nothing comes through, allow Spatial in
System Settings › Privacy & Security › Screen & System Audio Recording.

## Engines

- **System (AirPods Menu)** (default): no processing here. Spotify's stereo is played through
  `AVSampleBufferAudioRenderer` with `allowedAudioSpatializationFormats =
  .monoStereoAndMultichannel`, which makes this a spatial-capable app, so the AirPods menu
  in Control Center (Off / Fixed / Head Tracked) controls it and macOS renders it. A
  5 ms pump moves tap audio from a lock-free ring into the renderer; output wake-up delay
  (100-300 ms on AirPods) is trimmed in the first ~1.5 s, then it holds ~50 ms queued.
- **Apple Spatial Mixer**: `AUSpatialMixer` with `UseOutputType`, the stereo pair
  as an ambience bed, personalized HRTF on "auto". This is the renderer behind Spatialize
  Stereo. Head tracking is built in (`kAudioUnitProperty_SpatialMixerEnableHeadTracking`)
  or driven from CoreMotion. No room: the mixer ignores its reverb in this mode.
- **Virtual Speakers (3D engine)**: `AVAudioEnvironmentNode` in manual rendering mode, two
  HRTF point sources at ±30°, 2 m. Head tracking from `CMHeadphoneMotionManager`. Optional
  Room reverb.

To spatialize another app: `defaults write local.spatial target <bundle id prefix>`.
