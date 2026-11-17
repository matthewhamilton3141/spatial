#!/bin/sh
#
# install.sh: install the latest Spatial into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/matthewhamilton3141/spatial/main/install.sh | sh
#
# Downloads the newest release's Spatial.zip from GitHub, copies Spatial.app into
# /Applications (replacing an older copy), and opens it.
#
# Why this needs no Open Anyway: macOS only quarantines files saved by apps that opt
# in, such as Safari and Chrome. curl doesn't, so a zip fetched here is never
# flagged, and Gatekeeper never stops the app inside it.
#
# Options, as environment variables in front of `sh`:
#   SPATIAL_INSTALL_DIR=~/Applications   install somewhere other than /Applications
#   SPATIAL_NO_OPEN=1                    don't open Spatial afterwards
#   SPATIAL_ZIP_URL=...                  download from somewhere else (testing)
#
# Everything runs inside main(), called on the last line, so a download cut off
# partway through runs nothing at all.

set -eu

REPO="matthewhamilton3141/spatial"
BUNDLE_ID="local.spatial"
ZIP_URL="https://github.com/$REPO/releases/latest/download/Spatial.zip"

say() { printf '%s\n' "$*"; }
die() { printf 'spatial: %s\n' "$*" >&2; exit 1; }

tmp=""
sudo=""
dest=""
staged=""   # the new copy, next to the destination until it's swapped in
old=""      # the previous Spatial.app, moved aside until the swap succeeds
cleanup() {
    if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
    # Interrupted (Ctrl-C, Terminal closed) or failed partway: never leave a
    # half-copied app behind, and put the previous version back.
    if [ -n "$staged" ] && [ -e "$staged" ]; then $sudo rm -rf "$staged"; fi
    if [ -n "$old" ] && [ -e "$old" ]; then
        if [ -e "$dest" ]; then $sudo rm -rf "$old"; else $sudo mv "$old" "$dest"; fi
    fi
}

main() {
    [ "$(uname -s)" = "Darwin" ] || die "Spatial runs on macOS only."
    # hw.optional.arm64 is 1 on Apple silicon even inside a Rosetta shell.
    [ "$(sysctl -in hw.optional.arm64 2>/dev/null || echo 0)" = "1" ] \
        || die "Spatial needs a Mac with Apple silicon."

    dest_dir="${SPATIAL_INSTALL_DIR:-/Applications}"
    dest="$dest_dir/Spatial.app"
    url="${SPATIAL_ZIP_URL:-$ZIP_URL}"

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/spatial-install.XXXXXX")"
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    # --- Download and check -----------------------------------------------
    say "Downloading Spatial"
    curl -fL --retry 3 --progress-bar "$url" -o "$tmp/Spatial.zip" \
        || die "the download failed. Check your connection, or get the zip from https://github.com/$REPO/releases."
    mkdir "$tmp/x"
    ditto -x -k "$tmp/Spatial.zip" "$tmp/x" 2>/dev/null \
        || die "the zip wouldn't open; it may be incomplete. Run the command again."

    src="$tmp/x/Spatial.app"
    [ -d "$src" ] || die "the zip has no Spatial.app in it."
    plist="$src/Contents/Info.plist"
    id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    [ "$id" = "$BUNDLE_ID" ] || die "the zip holds the wrong app (${id:-unknown})."
    codesign --verify --deep --strict "$src" 2>/dev/null \
        || die "Spatial.app in the zip fails its code-signature check."
    version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist" 2>/dev/null || echo "?")"
    min_os="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$plist" 2>/dev/null || echo 15.0)"
    os="$(sw_vers -productVersion)"
    if [ "${os%%.*}" -lt "${min_os%%.*}" ]; then
        die "Spatial $version needs macOS $min_os or newer; this Mac has $os."
    fi
    say "Installing Spatial $version"

    # --- Quit a running copy ----------------------------------------------
    # Asked to quit, not killed: on the way out Spatial removes its audio tap
    # and hands Spotify back to your headphones.
    if pgrep -qf "^$dest/Contents/MacOS/Spatial" 2>/dev/null; then
        say "Quitting the running Spatial"
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        i=0
        while pgrep -qf "^$dest/Contents/MacOS/Spatial" 2>/dev/null; do
            i=$((i + 1))
            [ "$i" -le 40 ] || die "Spatial didn't quit. Choose Quit Spatial in its menu, then run this again."
            sleep 0.25
        done
    fi

    # --- Install ----------------------------------------------------------
    # /Applications is writable by admin accounts. Anyone else goes through
    # sudo, and the copy is handed back to them afterwards.
    mkdir -p "$dest_dir" 2>/dev/null || true
    if [ ! -w "$dest_dir" ] || { [ -e "$dest" ] && [ ! -w "$dest" ]; }; then
        say "$dest_dir isn't writable by $(id -un); asking for your password"
        sudo="sudo"
        $sudo mkdir -p "$dest_dir"
    fi

    # Copy next to the destination first, then swap with two renames: an
    # interruption leaves either the old app or the new one, never half of
    # one (cleanup() removes the leftovers).
    staged="$dest_dir/.Spatial-new-$$.app"
    $sudo rm -rf "$staged"
    $sudo ditto "$src" "$staged" \
        || die "copying Spatial into $dest_dir failed; nothing was changed."
    if [ -n "$sudo" ]; then $sudo chown -R "$(id -u):$(id -g)" "$staged"; fi
    if [ -e "$dest" ]; then
        old="$dest_dir/.Spatial-previous-$$.app"
        $sudo mv "$dest" "$old"
    fi
    $sudo mv "$staged" "$dest" \
        || die "couldn't put Spatial into $dest_dir; nothing was changed."
    staged=""
    if [ -n "$old" ]; then $sudo rm -rf "$old"; old=""; fi

    # Nothing above sets the flag; this only makes sure of it.
    xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

    say "Installed $dest"

    if [ -z "${SPATIAL_NO_OPEN:-}" ]; then
        open "$dest"
        say "Spatial is in your menu bar (the dotted diamond)."
        say "Play something in Spotify, allow System Audio Recording when asked, then pick"
        say "Fixed or Head Tracked in Control Center > your AirPods > Spatial Audio."
    fi
}

main "$@"
