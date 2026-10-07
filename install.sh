#!/usr/bin/env bash
#
# OonaCode installer for Linux and macOS — the twin of packaging/install.ps1.
#
#     curl -fsSL https://oonacode.oonak.ai/install.sh | bash
#
# It installs Form A: the `oona` terminal, the headless host service and the local web UI, plus
# the per-user systemd unit that keeps the host running (that is the product's core property, not
# an extra). The source repo is private, so everything is served from our own origin: the release
# feed at <origin>/api/releases/latest[?channel=dev] says which version is newest, and the
# artefacts live under <origin>/releases/download/v<version>/ (dev: …/download/dev/v<version>/).
#
# What it does, in order:
#   1. checks the platform (Linux x86_64; arm64 is refused until a build exists) and the tools it needs
#   2. asks the feed for the newest version (or takes --version / --archive)
#   3. downloads SHA256SUMS.txt and the tarball, and VERIFIES the checksum before unpacking
#   4. installs into <home>/bin, where <home> is $OONACODE_HOME, $XDG_DATA_HOME/oonacode or
#      ~/.oonacode — the same directory the host itself resolves
#   5. links `oona` (and `oonacode`) into ~/.local/bin, saying so if that is not on PATH, and
#      writes a desktop entry so OonaCode is in the applications menu like any other app
#   6. pre-fetches the coding engine once (docs/engine-once.md), so the first chat does not wait
#   7. installs and starts the systemd user service, and asks for lingering so it survives logout
#   8. installs or updates the desktop app — the AppImage, per user, in ~/Applications — with its
#      menu entry, as install.ps1 does with the Windows installer (--no-desktop skips it)
#
# Free disk space is checked before the download, before unpacking and before the copy, as
# install.ps1 does, so a full disk stops it with one sentence before anything is touched.
#
# It touches nothing outside those directories. A user's own Claude Code install (~/.claude) is
# never read or written (guardrail 6).
#
# MACOS (2026-10-03, macOS 12 and newer): the same steps, in macOS's places — <home> is
# ~/Library/Application Support/OonaCode (the directory the host resolves there; note the space),
# `oona` and `oonacode` are linked into ~/.local/bin and that is put on PATH through ~/.zprofile
# (zsh, macOS's default shell) or ~/.bash_profile, the background host is a launchd LaunchAgent
# (`oona service install`), and the desktop app is OonaCode.app in ~/Applications, unpacked from the
# release's OonaCode-<v>-mac-<arch>.zip — no sudo anywhere. The Mac builds are ad-hoc signed, with
# no Apple Developer ID yet (owner: "use same installation method as windows, from terminal"), and
# THIS script is how they are installed: curl sets no quarantine attribute, so Gatekeeper never
# assesses them, where a browser download would be refused. x64 and arm64 are both built, and the
# HARDWARE picks one (2026-10-06: under Rosetta 2 the x64 build has no AVX before macOS 15 and dies
# there); the Intel build on Apple Silicon only where it can run. The engine comes from the engine store like
# everywhere else (<home>/engine/<version>/oonaclaude, docs/engine-once.md). A local build installs
# with  install.sh --archive oonacode-darwin-x64.tar.gz [--app-zip OonaCode-<v>-mac-x64.zip]  (the
# app's zip is also found beside the archive). macOS ships no gpg: the release signature is
# checked when gpgv, gpg or sqv is installed (Homebrew), and said otherwise.
#
# SIGNATURES: every release's SHA256SUMS.txt is signed with the OonaCode release key (OpenPGP,
# fingerprint 2A9A 676E D0F3 E57E 6E47  B034 0C6E 08A6 9E51 5F40), and this script carries that
# key and checks SHA256SUMS.txt.asc with gpgv, gpg or sqv before anything is downloaded against
# it — so a server that serves both the files and their checksums still cannot slip in a file of
# its own (docs/linux-signing.md). A bad signature always stops the install. A MISSING signature
# stops a stable install — every stable release since 0.3.157 is signed — and --allow-unsigned then
# installs an older, unsigned release anyway; on the dev channel it is said, not refused, until its
# releases are signed too. A machine with none of the three tools is told so, and gets the
# checksums over HTTPS as before.
#
# Usage:
#   install.sh [--version X.Y.Z] [--channel stable|dev] [--origin URL] [--dir PATH]
#              [--archive FILE] [--no-service] [--no-engine] [--no-link] [--quiet]
#              [--no-desktop | --desktop] [--allow-unsigned] [--app-zip FILE (macOS)]
#   install.sh --uninstall [--keep-sessions | --delete-sessions]
#
# UNINSTALLING. `oona uninstall` is the normal route and this is the one that still works when
# `oona` does not — the twin of `install.ps1 -Uninstall`, which Windows has always had and this
# script did not. It does not reimplement the removal: it runs the current <origin>/uninstall.sh
# (as install.ps1 runs the current uninstall.ps1), and the copy the install carries at
# <home>/bin/uninstall.sh only when the site cannot be reached.

set -euo pipefail

# The origin this stack deploys to and the channel this copy installs by default. STAMPABLE: the
# dev website deploy rewrites these two lines (sed) to https://dev.oonacode.oonak.ai / dev — keep
# each a single, simple assignment on its own line (docs/dev-channel.md §4).
DEFAULT_ORIGIN='https://oonacode.oonak.ai'
DEFAULT_CHANNEL='stable'

ORIGIN="${OONACODE_ORIGIN:-$DEFAULT_ORIGIN}"
CHANNEL="${OONACODE_CHANNEL:-$DEFAULT_CHANNEL}"
VERSION=""
ARCHIVE=""
APP_ZIP=""
INSTALL_DIR=""
NO_SERVICE=0
NO_ENGINE=0
NO_LINK=0
QUIET=0
UNINSTALL=0
KEEP_SESSIONS=0
DELETE_SESSIONS=0
NO_DESKTOP=0
FORCE_DESKTOP=0
ALLOW_UNSIGNED=0
[ "${OONACODE_ALLOW_UNSIGNED:-}" = "1" ] && ALLOW_UNSIGNED=1
# A release with no SHA256SUMS.txt.asc is refused on the stable channel, whose releases are all
# signed from 0.3.157 on (--allow-unsigned installs an older one on purpose), and only said on
# the dev channel until its newest release is signed too. Decided after the arguments, by channel;
# OONACODE_REQUIRE_SIGNATURE=1 or 0 settles it either way.
SIGNATURES_REQUIRED=""
[ "${OONACODE_REQUIRE_SIGNATURE:-}" = "1" ] && SIGNATURES_REQUIRED=1
[ "${OONACODE_REQUIRE_SIGNATURE:-}" = "0" ] && SIGNATURES_REQUIRED=0
[ "${OONACODE_NO_SERVICE:-}" = "1" ] && NO_SERVICE=1
[ "${OONACODE_NO_ENGINE:-}" = "1" ] && NO_ENGINE=1
# What install.ps1 honours too: the desktop app sets it around its own `oona update`, because it
# updates itself — replacing it from here would be two updaters on one file.
[ "${OONACODE_NO_DESKTOP:-}" = "1" ] && NO_DESKTOP=1

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --origin) ORIGIN="${2:-}"; shift 2 ;;
    --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --archive) ARCHIVE="${2:-}"; shift 2 ;;
    --app-zip) APP_ZIP="${2:-}"; shift 2 ;;
    --no-service) NO_SERVICE=1; shift ;;
    --no-engine) NO_ENGINE=1; shift ;;
    --no-link) NO_LINK=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --no-desktop) NO_DESKTOP=1; shift ;;
    --desktop) FORCE_DESKTOP=1; shift ;;
    --allow-unsigned) ALLOW_UNSIGNED=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --keep-sessions) KEEP_SESSIONS=1; shift ;;
    --delete-sessions) DELETE_SESSIONS=1; shift ;;
    # The header down to its usage block, however long the header grows.
    -h|--help) awk 'NR > 1 && /^# UNINSTALLING/ {exit} NR > 1 {print}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SIGNATURES_REQUIRED" ]; then
  if [ "$CHANNEL" = "stable" ]; then SIGNATURES_REQUIRED=1; else SIGNATURES_REQUIRED=0; fi
fi

ORIGIN="${ORIGIN%/}"
DOWNLOAD_BASE="${OONACODE_DOWNLOAD_BASE:-$ORIGIN/releases/download}"
DOWNLOAD_BASE="${DOWNLOAD_BASE%/}"
RELEASES_API="${OONACODE_RELEASES_API:-$ORIGIN/api/releases/latest}"

if [ -t 1 ] && [ "$QUIET" = "0" ]; then
  C_STEP=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_OFF=$'\033[0m'
else
  C_STEP=""; C_OK=""; C_WARN=""; C_OFF=""
fi
step() { [ "$QUIET" = "1" ] || printf '%s==>%s %s\n' "$C_STEP" "$C_OFF" "$*"; }
note() { [ "$QUIET" = "1" ] || printf '    %s\n' "$*"; }
ok()   { [ "$QUIET" = "1" ] || printf '    %s%s%s\n' "$C_OK" "$*" "$C_OFF"; }
warn() { printf '    %s%s%s\n' "$C_WARN" "$*" "$C_OFF" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Apple Silicon: can this Mac run the Intel (x64) build at all? Only under Rosetta 2 on macOS 15 or
# newer — before 15 Rosetta gives Intel code no AVX, and the x64 bun runtime (oona's and the
# engine's) dies with an illegal instruction (2026-10-06, docs/macos-port.md §13). Prints why not.
x64_runs_here() { # <what led here>
  if [ "${mac_major:-0}" -lt 15 ]; then
    printf 'ERROR: %s, but the Intel build cannot run on this Mac: on macOS %s, Rosetta 2 gives Intel programs no AVX, which OonaCode needs (macOS 15 or newer has it). Install the Apple Silicon build instead (oonacode-darwin-arm64.tar.gz, or this installer without OONACODE_MAC_ARCH), or update macOS.\n' "$1" "${mac_version:-?}" >&2
    return 1
  fi
  if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    printf 'ERROR: %s, and the Intel build runs under Rosetta 2, which is not installed. Install it with:  softwareupdate --install-rosetta --agree-to-license  — then run this again.\n' "$1" >&2
    return 1
  fi
  return 0
}

TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------
# free space — install.ps1's Assert-FreeSpace, for Linux
# ---------------------------------------------------------------------------------------------
# The release is written twice (unpacked into $TMP, then copied into the install dir while the old
# one still sits beside it), the engine is ~250 MB once unpacked and the desktop app ~120 MB. On a
# full disk that surfaced as "cp: error writing …: No space left on device" halfway through the
# copy — a half-replaced install. Checked first, it is one sentence and nothing has been touched.
# /tmp is often a tmpfs sized from RAM, which is why it is checked on its own, and why the engine
# and the app are written where they will live rather than through it. All sizes are KiB: bash
# arithmetic is 64-bit, and awk (mawk on Ubuntu) prints big numbers in exponent form.
free_kib() { # <path> — KiB free on the filesystem that holds, or would hold, <path>; empty if unknown
  local p="$1"
  while [ ! -e "$p" ] && [ "$p" != "/" ] && [ "$p" != "." ]; do p="$(dirname "$p")"; done
  df -Pk "$p" 2>/dev/null | awk 'NR == 2 {print $4}'
}
mount_of() { # <path> — the mount point that holds, or would hold, <path>
  local p="$1"
  while [ ! -e "$p" ] && [ "$p" != "/" ] && [ "$p" != "." ]; do p="$(dirname "$p")"; done
  df -Pk "$p" 2>/dev/null | awk 'NR == 2 {print $6}'
}
human_kib() { # <KiB> — "387 MB", "1.25 GB"
  if [ "$1" -ge 1048576 ]; then
    printf '%d.%02d GB' $(( $1 / 1048576 )) $(( $1 % 1048576 * 100 / 1048576 ))
  else
    printf '%d MB' $(( $1 / 1024 ))
  fi
}
# True when <path>'s filesystem has <KiB> free — or when that cannot be told (an odd filesystem):
# then the step runs as it always did rather than refusing on a guess.
enough_space() { # <path> <KiB>
  local free; free="$(free_kib "$1")"
  case "$free" in '' | *[!0-9]*) return 0 ;; esac
  [ "$free" -ge "$2" ]
}
space_message() { # <path> <KiB> <what>
  printf 'not enough free disk space on %s for %s — free: %s, needed: about %s' \
    "$(mount_of "$1")" "$3" "$(human_kib "$(free_kib "$1")")" "$(human_kib "$2")"
}
# Refuses, before anything is changed.
need_space() { # <path> <KiB> <what>
  enough_space "$1" "$2" && return 0
  die "$(space_message "$1" "$2" "$3"). Free some space and run this again — nothing was changed. (The install can go elsewhere with --dir, the download with TMPDIR.)"
}

# ---------------------------------------------------------------------------------------------
# the release signature (docs/linux-signing.md)
# ---------------------------------------------------------------------------------------------
# The public half of the OonaCode release key, pinned HERE: the key has to come from somewhere the
# download server does not control, or a server that swaps a tarball could swap the key with it.
# Base64 of the binary key (gpg --export), which gpgv, gpg and sqv all read. The same key is served
# at <origin>/linux/oonacode.asc for apt, dnf and anyone checking by hand.
RELEASE_KEY_FPR='2A9A676ED0F3E57E6E47B0340C6E08A69E515F40'
release_key() {
  base64 -d <<'RELEASE_KEY'
mQINBGq4PfMBEADVsRBmA4whudb4A4EFK6Qc3yf5biOAxLZSG74PCh3jL9HSCUOLxccwaGZ/eGj/
slinCyh62CFDo4M7DwLxeHpeVJ7EmcistQxGQExsXb/A74WRAKHZQtPes4i1wOa5g04YuGwJmb8w
EqcnKhGBXHTa6cBsWPh3IBYFBCO+0ZjE3zuPmtzbw+y3sT4pdmSX1W36CMS06hqyyqBGAaTbo44h
bvD2itlBZtirxUBDyNVAVBftJ+tl0cKeVfKE4oBB7WuuwpbPNEGSGwU2K4Xs3dS69fpXEDxUgP/m
rSTa2VtYOBfsIlWJYVC8FwQp1RWNKGlHSIuPEhPlQpgutHN2zDSM5kiqZCgD4l9afNhnrNrafPya
fxGIttlm6gc/J/b653WMW/Mxd1oOtZY7P5Tn37O7gtUo57RXMMLw8PyHEaCQIz+eIB6Tw30xdRaT
SU81YIBgDsNrPf7mAwMsSx3hQ3OvT3MrCpPx6IfmOUbr60ZajVozvLabdwjdtE70zDSm0LrBqtyB
GqJSrQ3lbsIT1eltF6/YiOhamR4taefkGxk3Ud7nw54S3wFDYuOYrpmCzdgs/AxzOn2/qVjjIteW
Twwq+oSzMUW+77X8iO/veHcsYa3gRAUBpuU/KTXtuC1nLcef5Li12skHER43qC1nET6gDhwcQlhp
IGCK55ghWqbbKQARAQABtFZPb25hQ29kZSBSZWxlYXNlIFNpZ25pbmcgKExpbnV4IHBhY2thZ2Vz
LCByZXBvc2l0b3JpZXMgYW5kIGNoZWNrc3VtcykgPGhlbGxvQG9vbmFrLmFpPokCTgQTAQoAOBYh
BCqaZ27Q8+V+bkewNAxuCKaeUV9ABQJquD3zAhsDBQsJCAcCBhUKCQgLAgQWAgMBAh4BAheAAAoJ
EAxuCKaeUV9A2koP/1i+GUl2bBhjTZPA9E2QFX4yAme9euM9iWKPUH/A8iSJtZ7fOiF6QOZRNAjd
KRmWvLor+KxPJFhZHc4eKSfwU97Mfsrq4nuBjavqi6G3RfppbDPI1QinkHGKIFuHW0ZB1sFfHuXz
P71ndKhHlniHQH8VSeZ/ObgU9ndTXWyFS2L/1dDeLbttDa1Oc4VPQoQUMJS5nfyyWUPIaBc49dic
WSI+2nwmKEpbqmokT+qsqyJtkAi2IfbRrAq7qVvBygVxOssSlObtUbwbn7LZ/Qm2S1qzFSk1fxHI
JQy9TYx7AFR3Ed0PIez5r2BPUrY0549bdxXLfhN55YItD/A8mrWvP55OOXaAGqBbw4ApPGA+ysfC
zZOS4AJmR8/ecZWQiz4lFqAP4ynQ8EAB/MJhIUHLTtpVDiQVhI2xsEVYcplag+nPFruk79cZGb1T
jimEOvGaWBfS9r0tCQa3Beov3Q+od9PhXdisY4sEVaA/L8kOD51FAmC/KgoysIt5pMPNRhYA+m/Y
+Zt3x+Q6pVvJWhGRGk12bikshltTex7anTagg0hGv5cXaqP6pF1AlABtg0GsN84MObEOv1mE6e2x
fu2tN2NloNGUgPdb3jlo6vTMjzfXITNDJDLfsMC4AcJsic/RnDpRzxAC9/zKiau5Ry1m/KHhTH5e
6+Yq9Km3xJMQ4DU+
RELEASE_KEY
}

# A mirror's own key, or a test's: the file (binary, `gpg --export`) and its fingerprint — the
# override install.ps1 has too (OONACODE_SUMS_PUBLIC_KEY). Whoever can set this process's
# environment already runs code as the user, so it opens nothing.
if [ -n "${OONACODE_RELEASE_KEY_FILE:-}" ]; then
  release_key() { cat "$OONACODE_RELEASE_KEY_FILE"; }
  RELEASE_KEY_FPR="${OONACODE_RELEASE_KEY_FPR:-}"
fi

# Is <sig> a good signature over <file> by the release key? 0 yes, 1 no, 2 cannot tell (no tool).
# The signer's fingerprint is checked, not only the signature: gpgv also reads the user's own
# trustedkeys, and a good signature by some other key there must not pass.
verify_signed() { # <file> <sig>
  local key="$TMP/oonacode-release.gpg" out
  release_key > "$key" 2>/dev/null || return 2
  if command -v gpgv >/dev/null 2>&1; then
    out="$(gpgv --status-fd 1 --keyring "$key" "$2" "$1" 2>/dev/null)" || return 1
    case "$out" in *"VALIDSIG $RELEASE_KEY_FPR"*) return 0 ;; *) return 1 ;; esac
  fi
  if command -v gpg >/dev/null 2>&1; then
    local home="$TMP/gnupg"
    mkdir -p "$home" && chmod 700 "$home"
    gpg --homedir "$home" --batch --quiet --import "$key" >/dev/null 2>&1 || return 1
    out="$(gpg --homedir "$home" --batch --status-fd 1 --verify "$2" "$1" 2>/dev/null)" || return 1
    case "$out" in *"VALIDSIG $RELEASE_KEY_FPR"*) return 0 ;; *) return 1 ;; esac
  fi
  if command -v sqv >/dev/null 2>&1; then
    # sqv prints the fingerprint of each key that made a good signature, and fails otherwise.
    out="$(sqv --keyring "$key" "$2" "$1" 2>/dev/null)" || return 1
    case "$out" in *"$RELEASE_KEY_FPR"*) return 0 ;; *) return 1 ;; esac
  fi
  return 2
}

# ---------------------------------------------------------------------------------------------
# 1. the platform, and the tools this needs
# ---------------------------------------------------------------------------------------------
case "$(uname -s)" in
  Linux) PLATFORM="linux" ;;
  # macOS (see MACOS in the header): its own places, its own service manager, and a LOCAL build
  # until a signed one is published.
  Darwin) PLATFORM="darwin" ;;
  *) die "this installer is for Linux and macOS; on Windows run: irm $ORIGIN/install.ps1 | iex" ;;
esac
if [ "$PLATFORM" = "darwin" ]; then
  mac_version="$(sw_vers -productVersion 2>/dev/null || true)"
  mac_major="${mac_version%%.*}"
  case "$mac_major" in ''|*[!0-9]*) mac_major=0 ;; esac
  # The HARDWARE, not this process: a shell started under Rosetta 2 — by the x64 `oona update`, or a
  # Terminal set to open with Rosetta — reads `uname -m` as x86_64 on Apple Silicon too.
  APPLE_SILICON=0
  if [ "$(uname -m)" = "arm64" ] || [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
    APPLE_SILICON=1
  fi
  if [ "$APPLE_SILICON" = "1" ]; then
    # The native build (2026-10-06). The x64 one is NOT a fallback that always works: Rosetta 2
    # gives x64 code no AVX before macOS 15, and the x64 bun runtime — ours and the engine's — dies
    # there with an illegal instruction (a user's M3 MacBook on macOS 14 could neither chat nor
    # update; docs/macos-port.md §13). OONACODE_MAC_ARCH=x64 still forces it.
    ARCH="${OONACODE_MAC_ARCH:-arm64}"
  else
    ARCH="x64"
  fi
  case "$ARCH" in x64|arm64) ;; *) die "OONACODE_MAC_ARCH must be x64 or arm64" ;; esac
  # A local --archive says which arch it is in its name.
  asked_for="the Intel (x64) build was asked for"
  case "$(basename "${ARCHIVE:-}")" in
    oonacode-darwin-x64.tar.gz) ARCH="x64"; asked_for="--archive $(basename "$ARCHIVE") is the Intel (x64) build" ;;
    oonacode-darwin-arm64.tar.gz) ARCH="arm64" ;;
  esac
  if [ "$UNINSTALL" != "1" ]; then
    # An Intel Mac cannot run the Apple Silicon build at all.
    if [ "$APPLE_SILICON" != "1" ] && [ "$ARCH" = "arm64" ]; then
      die "this is an Intel Mac, and $(if [ -n "$ARCHIVE" ]; then echo "--archive $(basename "$ARCHIVE")"; else echo "OONACODE_MAC_ARCH=arm64"; fi) is the Apple Silicon build — it cannot run here. Use oonacode-darwin-x64.tar.gz (or no OONACODE_MAC_ARCH)."
    fi
    if [ "$APPLE_SILICON" = "1" ] && [ "$ARCH" = "x64" ]; then
      x64_runs_here "$asked_for" || exit 1
    fi
  fi
  # Electron 44, the desktop app's runtime, needs macOS 12; the terminal half is held to the same.
  case "$mac_version" in
    10.*|11.*) [ "$UNINSTALL" = "1" ] || die "OonaCode needs macOS 12 Monterey or newer, and this Mac runs macOS $mac_version" ;;
  esac
else
case "$(uname -m)" in
  x86_64|amd64) ARCH="x64" ;;
  aarch64|arm64)
    # No arm64 build has ever been published (docs/linux-team-handoff.md §3, gap 13): step 3 would
    # 404 and nothing would be installed. Refuse here, in one sentence that names the arch. The
    # detection stays so that the day an oonacode-linux-arm64.tar.gz exists this is the only line
    # to change back to `ARCH="arm64"`.
    die "this is an $(uname -m) machine, and OonaCode publishes no Linux arm64 build yet — only x86_64 can be installed today"
    ;;
  *) die "unsupported architecture $(uname -m) (only x86_64 is published)" ;;
esac
fi

# The C library. Every binary OonaCode ships is built for glibc and loads on GLIBC_FLOOR and newer
# (measured: the SQLite and terminal addons need 2.34; packaging/scripts/check-glibc-floor.sh holds
# every build to it — the two move together). Anything older, or a musl system, installed and then
# failed at the first start in a way nobody could read, so it is refused here in one sentence.
# Never for --uninstall: removing OonaCode must work wherever it was installed.
GLIBC_FLOOR="2.34"
if [ "$UNINSTALL" != "1" ] && [ "$PLATFORM" = "linux" ]; then
  os_name="$( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}") || true)"
  os_name="${os_name:-this system}"
  # Read first, matched after: musl's ldd answers --version with exit 1, which pipefail would make
  # the whole pipeline's status.
  libc_banner="$(ldd --version 2>&1 | head -n 1 || true)"
  case "$libc_banner" in
    *[Mm]usl*) die "$os_name uses the musl C library, and OonaCode is built for glibc — it cannot run here (Alpine, Void musl and other musl systems are not supported)" ;;
  esac
  glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)"
  if [ -n "$glibc" ] &&
    [ "$(printf '%s\n%s\n' "$glibc" "$GLIBC_FLOOR" | sort -V | head -n 1)" != "$GLIBC_FLOOR" ]; then
    die "OonaCode needs glibc $GLIBC_FLOOR or newer, and $os_name has $glibc — it runs on Ubuntu 22.04, Debian 12, Fedora, RHEL/Rocky/Alma 9, Linux Mint 21 and newer"
  fi
fi

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"; }
  fetch_text() { curl -fsSL --retry 3 --retry-delay 2 "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
  fetch_text() { wget -q -O - "$1"; }
else
  die "neither curl nor wget is installed — install one and run this again"
fi
command -v tar >/dev/null 2>&1 || die "tar is not installed"
if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  die "neither sha256sum nor shasum is installed — the download could not be verified"
fi

# The home the host itself resolves (resolveOonaHome in @oonacode/shared): the installer must
# agree with it, or the service would run against a different directory than the one we filled.
if [ -n "${OONACODE_HOME:-}" ]; then
  HOME_DIR="$OONACODE_HOME"
elif [ "$PLATFORM" = "darwin" ]; then
  # macOS has no XDG: the host resolves ~/Library/Application Support/OonaCode. Mind the space —
  # every use of these paths below is quoted.
  HOME_DIR="$HOME/Library/Application Support/OonaCode"
elif [ -n "${XDG_DATA_HOME:-}" ]; then
  HOME_DIR="${XDG_DATA_HOME%/}/oonacode"
else
  HOME_DIR="$HOME/.oonacode"
fi
[ -n "$INSTALL_DIR" ] || INSTALL_DIR="$HOME_DIR/bin"

# ---------------------------------------------------------------------------------------------
# 1b. --uninstall: hand over to the real uninstaller and stop
# ---------------------------------------------------------------------------------------------
# Placed here because it needs $HOME_DIR and `fetch`, and nothing below it. The removal itself is
# NOT reimplemented: uninstall.sh stops the service, undoes lingering only when the install turned
# it on, removes the PATH links, the desktop entry and the data — 170 lines that must not exist
# twice and drift apart.
if [ "$UNINSTALL" = "1" ]; then
  step "OonaCode uninstaller"
  note "home: $HOME_DIR"
  args=()
  [ "$KEEP_SESSIONS" = "1" ] && args+=(--keep-sessions)
  [ "$DELETE_SESSIONS" = "1" ] && args+=(--delete-sessions)
  shipped="$INSTALL_DIR/uninstall.sh"
  TMP="$(mktemp -d)"
  # ALWAYS from a temp copy, never in place. uninstall.sh deletes <home>, which is where the
  # shipped copy lives, and bash reads a script incrementally — deleting it mid-run is how a
  # removal stops halfway through with no error. `oona uninstall` stages it for the same reason
  # (cli/src/commands/uninstall.ts: "copied to a temp directory ... whose own binary it deletes").
  #
  # The CURRENT uninstaller first, as `install.ps1 -Uninstall` does: the copy an install shipped
  # with is as old as the install, and misses what later ones learned — taking the PC off the
  # account, never emptying a home that is not OonaCode's (docs/uninstall.md). The shipped copy is
  # the fallback when the site cannot be reached; anything that is not the uninstaller (a captive
  # portal's page) is refused.
  # On a Mac the current one must also KNOW macOS: an uninstaller from before the macOS port looks
  # for ~/.oonacode and systemd, finds neither, and would report a removal it never did.
  current_why="$ORIGIN/uninstall.sh could not be fetched"
  if fetch "$ORIGIN/uninstall.sh" "$TMP/uninstall.sh" 2>/dev/null &&
    head -n 1 "$TMP/uninstall.sh" | grep -q '^#!' &&
    grep -q 'Uninstall OonaCode' "$TMP/uninstall.sh" &&
    { [ "$PLATFORM" != "darwin" ] || grep -q 'Darwin' "$TMP/uninstall.sh" || { current_why="the one at $ORIGIN does not know macOS yet"; false; }; }; then
    note "using the current uninstaller from $ORIGIN"
  elif [ -f "$shipped" ]; then
    note "using the uninstaller this install shipped with ($current_why)"
    cp "$shipped" "$TMP/uninstall.sh"
  elif [ "$PLATFORM" = "darwin" ]; then
    die "could not download a macOS uninstaller from $ORIGIN, and this install carries none. Remove \"$HOME_DIR\" by hand, plus the oona link in ~/.local/bin, ~/Applications/OonaCode.app and the LaunchAgent ~/Library/LaunchAgents/ai.oonak.oonacode.host.plist (launchctl bootout gui/\$(id -u)/ai.oonak.oonacode.host first)."
  else
    die "could not download $ORIGIN/uninstall.sh, and this install carries no uninstaller. Remove $HOME_DIR by hand, plus the oona link in ~/.local/bin and the systemd user unit oonacode-host.service."
  fi
  # Where this install's oona is (--dir), for the uninstaller's account step; an uninstaller from
  # before --bin-dir refuses arguments it does not know, so it is told only when it knows.
  grep -q -- '--bin-dir' "$TMP/uninstall.sh" && args+=(--bin-dir "$INSTALL_DIR")
  # Not `exec`: the EXIT trap has to survive to clear $TMP, and the uninstaller is finished by
  # the time it runs (it is /tmp, never the directory being removed).
  bash "$TMP/uninstall.sh" ${args[@]+"${args[@]}"}
  exit $?
fi

step "OonaCode installer ($PLATFORM-$ARCH, $CHANNEL channel)"
note "origin: $ORIGIN"
note "home:   $HOME_DIR"
# The engine refuses `--dangerously-skip-permissions` as root ("cannot be used with root/sudo
# privileges for security reasons"), so a root install runs turns without the option to switch to
# bypassPermissions at all. Everything else works; say so once, here, rather than leaving it to be
# discovered mid-chat.
if [ "$(id -u)" = "0" ]; then
  warn "installing as root: the coding engine will not offer the 'never ask' permission mode (it refuses it for root). Everything else works."
  warn "to install for a normal user instead, run this as that user — e.g."
  warn "  sudo --user <name> --login bash -c 'curl -fsSL $ORIGIN/install.sh | bash'"
  warn "  WSL: 'wsl --user <name>' (or make <name> the distro's default user); a container: 'useradd -m <name>' first"
fi

# ---------------------------------------------------------------------------------------------
# 2. which version
# ---------------------------------------------------------------------------------------------
# One field out of a small JSON document, without assuming python or jq is installed: node when
# it is there (exact), a sed extraction otherwise.
json_field() { # <json> <field>
  if command -v node >/dev/null 2>&1; then
    printf '%s' "$1" | node -e '
      let raw = "";
      process.stdin.on("data", (c) => (raw += c)).on("end", () => {
        try { const v = JSON.parse(raw)[process.argv[1]]; if (typeof v === "string") process.stdout.write(v); } catch {}
      });' "$2"
  else
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
  fi
}

if [ -n "$ARCHIVE" ]; then
  step "2/8 local archive"
  [ -f "$ARCHIVE" ] || die "--archive $ARCHIVE does not exist"
  note "$ARCHIVE"
elif [ -n "$VERSION" ]; then
  step "2/8 version $VERSION (given)"
else
  step "2/8 asking the release feed which version is newest"
  # Asked for THIS machine: the newest release is not always one Linux can install (from 0.3.20 to
  # 0.3.147 none carried a Linux build, and this line took their version and walked into a 404).
  # With ?platform= the feed answers the newest release that carries the Linux payload; a gateway
  # that predates the filter ignores it and answers the newest release, as before.
  feed_url="$RELEASES_API?platform=$PLATFORM&arch=$ARCH"
  [ "$CHANNEL" = "dev" ] && feed_url="$feed_url&channel=dev"
  feed="$(fetch_text "$feed_url" || true)"
  [ -n "$feed" ] || die "could not reach the release feed at $feed_url"
  VERSION="$(json_field "$feed" version)"
  [ -n "$VERSION" ] || die "the release feed at $feed_url named no version"
  # Apple Silicon before an arm64 release exists on this channel: the Intel build, where it can run.
  if [ "$VERSION" = "0.0.0" ] && [ "$PLATFORM" = "darwin" ] && [ "$ARCH" = "arm64" ] &&
    [ -z "${OONACODE_MAC_ARCH:-}" ]; then
    x64_runs_here "no Apple Silicon build has been published on the $CHANNEL channel yet" || exit 1
    ARCH="x64"
    warn "no Apple Silicon build on the $CHANNEL channel yet — installing the Intel build, which this Mac runs under Rosetta 2"
    feed_url="$RELEASES_API?platform=$PLATFORM&arch=$ARCH"
    [ "$CHANNEL" = "dev" ] && feed_url="$feed_url&channel=dev"
    feed="$(fetch_text "$feed_url" || true)"
    VERSION="$(json_field "$feed" version)"
    [ -n "$VERSION" ] || die "the release feed at $feed_url named no version"
  fi
  # macOS: the feed answers 0.0.0 while no release on this channel carries a darwin-<arch> build.
  [ "$VERSION" != "0.0.0" ] || [ "$PLATFORM" != "darwin" ] ||
    die "no macOS ($ARCH) release has been published on the $CHANNEL channel yet — nothing to install"
  [ "$VERSION" != "0.0.0" ] || die "no Linux release has been published on the $CHANNEL channel yet — nothing to install"
  note "newest: $VERSION"
fi
VERSION="${VERSION#v}"

# ---------------------------------------------------------------------------------------------
# 3. download + verify
# ---------------------------------------------------------------------------------------------
tmp_root="${TMPDIR:-/tmp}"
TMP="$(mktemp -d "${tmp_root%/}/oonacode-install-XXXXXX")"
ASSET="oonacode-$PLATFORM-$ARCH.tar.gz"
PLATFORM_NAME="Linux"
[ "$PLATFORM" = "darwin" ] && PLATFORM_NAME="macOS"
# Floors, before a byte is fetched: the ~45 MB tarball unpacks to ~110 MB in $TMP, and the install
# dir takes that again while the old payload is still beside it. The exact sizes are checked again
# once they are known.
need_space "$TMP" $(( 200 * 1024 )) "the download"
need_space "$INSTALL_DIR" $(( 150 * 1024 )) "the install"
if [ -n "$ARCHIVE" ]; then
  cp "$ARCHIVE" "$TMP/$ASSET"
  # macOS: a local build comes with the SHA256SUMS.txt mac-builder.sh wrote beside it (dist\mac on
  # the dev PC). When it names this file, the copy is checked against it as a download would be.
  local_sums="$(dirname "$ARCHIVE")/SHA256SUMS.txt"
  if [ "$PLATFORM" = "darwin" ] && [ -f "$local_sums" ]; then
    expected="$(awk -v n="$(basename "$ARCHIVE")" '$2 == n || $2 == "*" n {print $1; exit}' "$local_sums")"
    if [ -n "$expected" ]; then
      [ "$(sha256_of "$TMP/$ASSET")" = "$expected" ] ||
        die "$ARCHIVE does not match the SHA256SUMS.txt beside it — nothing was installed"
      ok "checksum verified against $local_sums"
    fi
  fi
else
  base="$DOWNLOAD_BASE/v$VERSION"
  [ "$CHANNEL" = "dev" ] && base="$DOWNLOAD_BASE/dev/v$VERSION"
  step "3/8 downloading $ASSET"
  note "$base/$ASSET"
  fetch "$base/SHA256SUMS.txt" "$TMP/SHA256SUMS.txt" ||
    die "no SHA256SUMS.txt at $base — is $VERSION published for this channel?"
  # A release from before the Apple Silicon build (asked for with --version) has only the Intel one.
  if [ "$PLATFORM" = "darwin" ] && [ "$ARCH" = "arm64" ] && [ -z "${OONACODE_MAC_ARCH:-}" ] &&
    ! awk -v n="$ASSET" '$2 == n || $2 == "*" n {f = 1} END {exit !f}' "$TMP/SHA256SUMS.txt"; then
    x64_runs_here "OonaCode $VERSION has no Apple Silicon build" || exit 1
    ARCH="x64"
    ASSET="oonacode-$PLATFORM-$ARCH.tar.gz"
    warn "OonaCode $VERSION has no Apple Silicon build — installing its Intel build, which this Mac runs under Rosetta 2"
    note "$base/$ASSET"
  fi
  if fetch "$base/SHA256SUMS.txt.asc" "$TMP/SHA256SUMS.txt.asc" 2>/dev/null; then
    sig=0
    verify_signed "$TMP/SHA256SUMS.txt" "$TMP/SHA256SUMS.txt.asc" || sig=$?
    case "$sig" in
      0) ok "signed by the OonaCode release key (…$(printf '%s' "$RELEASE_KEY_FPR" | tail -c 16))" ;;
      1) die "SHA256SUMS.txt at $base does not carry a good signature from the OonaCode release key — the release may have been tampered with. Nothing was installed." ;;
      *)
        gpg_hint="the gnupg package has them"
        [ "$PLATFORM" = "darwin" ] && gpg_hint="macOS ships none; Homebrew's gnupg has them"
        warn "the release signature cannot be checked here: none of gpgv, gpg or sqv is installed ($gpg_hint). The checksums still come over HTTPS from $ORIGIN." ;;
    esac
  elif [ "$ALLOW_UNSIGNED" = "1" ]; then
    warn "release $VERSION carries no signature (SHA256SUMS.txt.asc) — installing it anyway, as --allow-unsigned asks"
  elif [ "$SIGNATURES_REQUIRED" = "1" ]; then
    die "release $VERSION carries no signature (SHA256SUMS.txt.asc), so it cannot be checked. Releases before 0.3.157 have none: --allow-unsigned installs one anyway."
  else
    warn "release $VERSION carries no signature (SHA256SUMS.txt.asc): it was published before OonaCode signed its releases. Its checksums come over HTTPS from $ORIGIN."
  fi
  fetch "$base/$ASSET" "$TMP/$ASSET" ||
    die "could not download $base/$ASSET — this version may not publish a $PLATFORM_NAME build yet"
  expected="$(awk -v n="$ASSET" '$2 == n || $2 == "*" n {print $1; exit}' "$TMP/SHA256SUMS.txt")"
  [ -n "$expected" ] || die "SHA256SUMS.txt at $base does not name $ASSET"
  actual="$(sha256_of "$TMP/$ASSET")"
  [ "$actual" = "$expected" ] ||
    die "checksum mismatch for $ASSET (expected $expected, got $actual) — nothing was installed"
  ok "checksum verified"
fi

# ---------------------------------------------------------------------------------------------
# 4. unpack into place
# ---------------------------------------------------------------------------------------------
step "4/8 installing into $INSTALL_DIR"
# A tarball unpacks to ~2.5x its size; 3x leaves room to be wrong in the safe direction.
need_space "$TMP" $(( $(wc -c < "$TMP/$ASSET") / 1024 * 3 )) "unpacking the release"
mkdir -p "$TMP/unpacked"
tar -xzf "$TMP/$ASSET" -C "$TMP/unpacked"
[ -f "$TMP/unpacked/oona" ] || die "the archive has no oona binary — it is not a Form A build"
# The payload is measured, not estimated: the old install stays beside the new one until the copy
# has finished, so the new one must fit whole (with 15% to spare, as install.ps1 allows).
payload_kib="$(du -sk "$TMP/unpacked" 2>/dev/null | cut -f1)"
case "$payload_kib" in '' | *[!0-9]*) payload_kib=0 ;; esac
need_space "$INSTALL_DIR" $(( payload_kib + payload_kib * 15 / 100 )) "installing the release"

# The installed CLI's own account of the background host — `oona service status --json`, one key
# per line — which is what install.ps1 plans from too (Resolve-ServicePlan). Read with grep and
# sed: this script assumes no node or python on the machine.
service_status() { "$1" service status --json 2>/dev/null || true; }
status_is() { printf '%s' "$1" | grep -q "\"$2\": *$3"; }
status_str() { printf '%s' "$1" | sed -n "s/^ *\"$2\": *\"\([^\"]*\)\".*/\1/p" | head -1; }

# Stop a running host before its own binary is replaced (a busy file is not an error on Linux,
# but a half-swapped install would keep serving the old code until something restarted it) — but
# never one the desktop app's unit runs: that host runs from the app, not from these files, and
# `service stop` would also DISABLE the app's unit (install.ps1 leaves a desktop-owned task alone
# for the same reason).
if [ -x "$INSTALL_DIR/oona" ] && [ "$NO_SERVICE" = "0" ]; then
  old_status="$(service_status "$INSTALL_DIR/oona")"
  if status_is "$old_status" running true && [ "$(status_str "$old_status" launcherForm)" != "desktop" ]; then
    "$INSTALL_DIR/oona" service stop >/dev/null 2>&1 || true
  fi
fi
mkdir -p "$INSTALL_DIR"
# Replace the payload, never the siblings: host/ (the sessions database and this machine's
# identity), workspaces/ and engine/ live beside bin/ and must survive every upgrade.
rm -rf "$INSTALL_DIR.old"
if [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
  mv "$INSTALL_DIR" "$INSTALL_DIR.old"
  mkdir -p "$INSTALL_DIR"
fi
cp -r "$TMP/unpacked/." "$INSTALL_DIR/"
chmod 0755 "$INSTALL_DIR/oona"
[ -f "$INSTALL_DIR/oonaclaude" ] && chmod 0755 "$INSTALL_DIR/oonaclaude"
[ -f "$INSTALL_DIR/uninstall.sh" ] && chmod 0755 "$INSTALL_DIR/uninstall.sh"
# macOS: node-pty starts every terminal through its spawn-helper, which npm publishes 0644
# (build-mac.sh stages it 0755; this holds for a payload that lost the bit on the way).
for helper in "$INSTALL_DIR"/node_modules/node-pty/prebuilds/darwin-*/spawn-helper; do
  if [ -f "$helper" ]; then chmod 0755 "$helper"; fi
done
rm -rf "$INSTALL_DIR.old"
# Done with them: on a tmpfs /tmp they are RAM, and the engine step comes next.
rm -rf "$TMP/unpacked" "$TMP/$ASSET"
installed_version="$("$INSTALL_DIR/oona" --version 2>/dev/null | head -1 || true)"

# The install marker (`formatInstallMarker` in packages/shared/src/release-channel.ts, and what
# install.ps1 writes): line 1 the bare version, then key=value. `oona update`, the title-bar badge
# and `oona --version` read it to know which channel and origin this install came from — without
# it an upgrade would silently fall back to the stable defaults.
marker_version="$VERSION"
[ -n "$marker_version" ] || marker_version="${installed_version%% *}"
{
  printf '%s\n' "${marker_version#v}"
  printf 'channel=%s\n' "$CHANNEL"
  printf 'origin=%s\n' "$ORIGIN"
} > "$INSTALL_DIR/.installed-version"
ok "installed ${installed_version:-$VERSION}"

# ---------------------------------------------------------------------------------------------
# 5. put `oona` on PATH
# ---------------------------------------------------------------------------------------------
# `oona` must work in the next terminal the person opens, as it does on Windows, where
# install.ps1 puts its bin on the user PATH. Debian, Ubuntu, Mint and their family put
# ~/.local/bin on PATH from ~/.profile only when it existed at LOGIN, so on a desktop where it was
# created later — by this install or any other — every terminal of that session answered
# "oona: command not found" until the next login (Linux Mint 22.3, 2026-09-28). So when this shell
# does not have it, one marked block goes into the startup file of each shell the person uses.
# uninstall.sh removes exactly that block: its first and last lines are what it looks for, so
# change them only together with uninstall.sh.
PATH_BLOCK_BEGIN='# >>> oonacode path >>>'
PATH_BLOCK_END='# <<< oonacode path <<<'
PATH_NOT_LIVE=0

# Appends the block to a bash or zsh startup file, unless it is already there.
add_path_block() {
  local rc="$1"
  if [ -f "$rc" ] && grep -qxF "$PATH_BLOCK_BEGIN" "$rc"; then return 0; fi
  # A last line with no newline would swallow the block's first line.
  if [ -s "$rc" ] && [ -n "$(tail -c 1 "$rc")" ]; then printf '\n' >> "$rc" || return 1; fi
  printf '%s\n' "$PATH_BLOCK_BEGIN" \
    '# Added by the OonaCode installer so new terminals find `oona`; `oona uninstall` removes it.' \
    'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac' \
    "$PATH_BLOCK_END" >> "$rc"
}

# Puts ~/.local/bin on PATH for the person's login shell, and for bash, zsh or fish too when that
# shell is already set up (its startup file exists). Prints the files it wrote, space-separated.
add_local_bin_to_shells() {
  local login_shell added="" zshrc fish_dir fish_file
  login_shell="$(basename "${SHELL:-}")"
  if [ "$PLATFORM" = "darwin" ]; then
    # macOS opens every Terminal window as a LOGIN shell: zsh (the default since 10.15) reads
    # ~/.zprofile, bash ~/.bash_profile — and neither reads the rc files Linux uses here unless told
    # to. zsh's default PATH there has no ~/.local/bin at all. The same marked block, in those two.
    local zprofile="${ZDOTDIR:-$HOME}/.zprofile"
    if [ "$login_shell" = "zsh" ] || [ -f "$zprofile" ] || [ -f "${ZDOTDIR:-$HOME}/.zshrc" ]; then
      add_path_block "$zprofile" && added="$added $zprofile"
    fi
    if [ "$login_shell" = "bash" ] || [ -f "$HOME/.bash_profile" ]; then
      add_path_block "$HOME/.bash_profile" && added="$added $HOME/.bash_profile"
    fi
  else
    if [ "$login_shell" = "bash" ] || [ -f "$HOME/.bashrc" ]; then
      add_path_block "$HOME/.bashrc" && added="$added $HOME/.bashrc"
    fi
    zshrc="${ZDOTDIR:-$HOME}/.zshrc"
    if [ "$login_shell" = "zsh" ] || [ -f "$zshrc" ]; then
      add_path_block "$zshrc" && added="$added $zshrc"
    fi
  fi
  fish_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fish"
  fish_file="$fish_dir/conf.d/oonacode-path.fish"
  if [ "$login_shell" = "fish" ] || [ -d "$fish_dir" ]; then
    if [ -f "$fish_file" ] || { mkdir -p "$fish_dir/conf.d" && printf '%s\n' \
        '# Added by the OonaCode installer so new terminals find `oona`; `oona uninstall` removes this file.' \
        'contains -- $HOME/.local/bin $PATH; or set -gx PATH $HOME/.local/bin $PATH' > "$fish_file"; }; then
      added="$added $fish_file"
    fi
  fi
  printf '%s' "${added# }" | sed "s|$HOME/|~/|g"
}

if [ "$NO_LINK" = "1" ]; then
  step "5/8 PATH (skipped: --no-link)"
else
  step "5/8 linking oona into ~/.local/bin"
  link_dir="$HOME/.local/bin"
  mkdir -p "$link_dir"
  ln -sf "$INSTALL_DIR/oona" "$link_dir/oona"
  # The terminal answers to both names (CLAUDE.md → Status).
  ln -sf "$INSTALL_DIR/oona" "$link_dir/oonacode"
  case ":$PATH:" in
    *":$link_dir:"*) ok "$link_dir is on PATH" ;;
    *)
      PATH_NOT_LIVE=1
      if path_added="$(add_local_bin_to_shells)" && [ -n "$path_added" ]; then
        ok "$link_dir added to PATH for new terminals ($path_added)"
      else
        warn "$link_dir is not on your PATH. Add this line to your shell's startup file:"
        warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
      fi
      ;;
  esac

  # macOS has no applications-menu entry for a terminal program: the app there is
  # OonaCode.app (step 8), and Spotlight finds it.
  if [ "$PLATFORM" = "linux" ]; then
    # A desktop entry, so OonaCode is in the applications menu like everything else. Without one a
    # Linux install is invisible: the binary is there and on PATH, and there is nothing to click —
    # which is exactly how it looked to the first person who tried it (2026-09-04).
    # `Terminal=true` lets the desktop open its own terminal, so this does not care which one is
    # installed.
    #
    # Named for what it opens — the TERMINAL. The desktop app (AppImage, .deb, .rpm) is
    # `oonacode.desktop`, and an entry in ~/.local/share/applications shadows a system one of the
    # same name: this one, when it was also called oonacode.desktop, hid the app it sat beside from
    # the menu (docs/linux-parity-plan.md bug 4). The old entry is removed — only when it is the one
    # this script wrote, never an app's.
    apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    icons_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
    mkdir -p "$apps_dir"
    icon_name="utilities-terminal"
    if [ -f "$INSTALL_DIR/oonacode.png" ]; then
      mkdir -p "$icons_dir"
      cp -f "$INSTALL_DIR/oonacode.png" "$icons_dir/oonacode.png" 2>/dev/null && icon_name="oonacode"
    fi
    old_entry="$apps_dir/oonacode.desktop"
    if [ -f "$old_entry" ] && grep -qx "Exec=$INSTALL_DIR/oona" "$old_entry" && grep -qx 'Terminal=true' "$old_entry"; then
      rm -f "$old_entry"
    fi
    cat > "$apps_dir/oonacode-terminal.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.0
Name=OonaCode Terminal
GenericName=Coding agent
Comment=The OonaCode terminal — the Claude Code engine, any provider
Exec=$INSTALL_DIR/oona
Icon=$icon_name
Terminal=true
Categories=Development;Utility;
Keywords=oona;oonacode;claude;agent;ai;coding;terminal;
StartupNotify=true
DESKTOP
    chmod 0644 "$apps_dir/oonacode-terminal.desktop"
    update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
    ok "added to the applications menu (OonaCode Terminal)"
  fi
fi

# ---------------------------------------------------------------------------------------------
# 6. the engine, once per PC and engine version (docs/engine-once.md)
# ---------------------------------------------------------------------------------------------
# Optional in every failure mode: the host downloads it on first use, so nothing here is fatal.
if [ "$NO_ENGINE" = "1" ]; then
  step "6/8 engine pre-fetch (skipped: --no-engine)"
elif [ ! -f "$INSTALL_DIR/engine.json" ]; then
  step "6/8 engine pre-fetch (no engine.json in this build)"
else
  step "6/8 engine pre-fetch"
  manifest="$(cat "$INSTALL_DIR/engine.json")"
  eng_version="$(json_field "$manifest" version)"
  eng_archive="$(json_field "$manifest" archive)"
  eng_exe="$(json_field "$manifest" executable)"
  eng_sums="$(json_field "$manifest" sums)"
  [ -n "$eng_sums" ] || eng_sums="SHA256SUMS.txt"
  store="$HOME_DIR/engine/$eng_version"
  # The store keeps one engine per version, not per arch: a Mac moving from the Intel build to the
  # Apple Silicon one still has the Intel engine in this very place, and would keep crashing on it.
  if [ "$PLATFORM" = "darwin" ] && [ -n "$eng_exe" ] && [ -f "$store/$eng_exe" ]; then
    eng_want="x86_64"
    [ "$ARCH" = "arm64" ] && eng_want="arm64"
    case "$(file -b "$store/$eng_exe" 2>/dev/null)" in
      *universal*|*"$eng_want"*) ;;
      *)
        rm -f "$store/$eng_exe"
        note "the stored engine v$eng_version is for the other Mac architecture — fetching this one's"
        ;;
    esac
  fi
  if [ -z "$eng_version" ] || [ -z "$eng_archive" ] || [ -z "$eng_exe" ]; then
    note "engine.json is incomplete — the first chat downloads the engine"
  elif [ -f "$store/$eng_exe" ]; then
    ok "engine v$eng_version is already in the store"
    # A bundled copy beside it is the same engine twice (~250 MB): the store's is the one used.
    [ "$PLATFORM" = "darwin" ] && [ -f "$INSTALL_DIR/$eng_exe" ] && rm -f "$INSTALL_DIR/$eng_exe"
  elif [ "$PLATFORM" = "darwin" ] && [ -f "$INSTALL_DIR/$eng_exe" ]; then
    # macOS: nothing publishes the darwin engine yet, so a payload built with --bundle-engine is how
    # a Mac gets one. It goes where docs/engine-once.md puts every engine — the store, shared with
    # the desktop app — instead of staying in bin/ as a second copy. Moved within one disk.
    if mkdir -p "$store" && mv -f "$INSTALL_DIR/$eng_exe" "$store/.$eng_exe.partial" &&
      chmod 0755 "$store/.$eng_exe.partial" && mv -f "$store/.$eng_exe.partial" "$store/$eng_exe"; then
      ok "engine v$eng_version (bundled with this build) stored at $store/$eng_exe"
      for old in "$HOME_DIR"/engine/*; do
        [ -d "$old" ] || continue
        [ "$(basename "$old")" = "$eng_version" ] && continue
        rm -rf "$old" 2>/dev/null && note "removed the older engine v$(basename "$old")"
      done
    else
      warn "could not move the bundled engine into $store — it stays beside oona, where the host finds it too"
    fi
  else
    eng_base="$DOWNLOAD_BASE/engine/$eng_version"
    # The archive (~100 MB) goes through $TMP; the engine (~250 MB) is unpacked straight into the
    # store. Short of either, it is left to the first chat — with the reason, since that download
    # will need the same room.
    eng_short=""
    enough_space "$TMP" $(( 128 * 1024 )) ||
      eng_short="$(space_message "$TMP" $(( 128 * 1024 )) "the engine download")"
    [ -n "$eng_short" ] || enough_space "$store" $(( 320 * 1024 )) ||
      eng_short="$(space_message "$store" $(( 320 * 1024 )) "the engine")"
    if [ -n "$eng_short" ]; then
      warn "$eng_short — skipped; free some space, and the first chat downloads it"
    elif ! fetch "$eng_base/$eng_sums" "$TMP/engine-sums.txt" 2>"$TMP/engine-sums.err"; then
      # macOS: curl's own 404 line stays off the screen — the sentence below is the whole story.
      [ "$PLATFORM" = "darwin" ] || cat "$TMP/engine-sums.err" >&2
      if [ "$PLATFORM" = "darwin" ]; then
        # Said plainly: the first chat would fetch the same file, and it is not there either.
        warn "the macOS engine v$eng_version is not at $eng_base/$eng_sums, so the first chat cannot download it either — run this again later, or install a build made with --bundle-engine"
      else
        note "engine v$eng_version is not published at $eng_base — the first chat downloads it when it is"
      fi
    else
      gz_sum="$(awk -v n="$eng_archive" '$2 == n || $2 == "*" n {print $1; exit}' "$TMP/engine-sums.txt")"
      exe_sum="$(awk -v n="$eng_exe" '$2 == n || $2 == "*" n {print $1; exit}' "$TMP/engine-sums.txt")"
      eng_partial="$store/.$eng_exe.partial"
      if [ -z "$gz_sum" ] || [ -z "$exe_sum" ]; then
        warn "engine checksums at $eng_base do not name $eng_archive — skipped; the first chat downloads it"
      elif ! fetch "$eng_base/$eng_archive" "$TMP/$eng_archive"; then
        warn "engine download failed — skipped; the first chat downloads it"
      elif [ "$(sha256_of "$TMP/$eng_archive")" != "$gz_sum" ]; then
        warn "engine archive checksum mismatch — discarded; the first chat downloads it"
      elif ! { mkdir -p "$store" && gzip -dc "$TMP/$eng_archive" > "$eng_partial"; }; then
        rm -f "$eng_partial" "$TMP/$eng_archive"
        rmdir "$store" 2>/dev/null || true
        warn "could not unpack the engine into $store (disk full?) — skipped; the first chat downloads it"
      elif rm -f "$TMP/$eng_archive" && [ "$(sha256_of "$eng_partial")" != "$exe_sum" ]; then
        rm -f "$eng_partial"
        rmdir "$store" 2>/dev/null || true
        warn "unpacked engine checksum mismatch — discarded; the first chat downloads it"
      else
        # 0755 before the rename: gzip writes 0644, and a 0644 engine is EACCES at every spawn.
        chmod 0755 "$eng_partial"
        mv -f "$eng_partial" "$store/$eng_exe"
        ok "engine v$eng_version stored at $store/$eng_exe"
        # One engine per PC: the other versions are ~150 MB each of nothing that still runs.
        for old in "$HOME_DIR"/engine/*; do
          [ -d "$old" ] || continue
          [ "$(basename "$old")" = "$eng_version" ] && continue
          rm -rf "$old" 2>/dev/null && note "removed the older engine v$(basename "$old")"
        done
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------------------------
# 7. the background host
# ---------------------------------------------------------------------------------------------
# Read again by the macOS desktop step (a host that runs from the app is stopped for its swap).
status=""
form=""
if [ "$NO_SERVICE" = "1" ]; then
  step "7/8 service (skipped: --no-service)"
  if [ "$PLATFORM" = "darwin" ]; then note "start one by hand with: \"$INSTALL_DIR/oona\" serve"
  else note "start one by hand with: $INSTALL_DIR/oona serve"
  fi
else
  # macOS: a launchd LaunchAgent (~/Library/LaunchAgents/ai.oonak.oonacode.host.plist, in the login
  # session's gui/<uid> domain) — `oona service` speaks to whichever the platform has.
  if [ "$PLATFORM" = "darwin" ]; then step "7/8 background host (launchd LaunchAgent)"
  else step "7/8 background host (systemd user service)"
  fi
  # What install.ps1 does (Resolve-ServicePlan): a unit the desktop app registered is the app's —
  # it runs the app's own host and updates with it — and a unit some other launcher registered is
  # never taken over silently. Otherwise: register (or repair a drifted launcher), then start.
  status="$(service_status "$INSTALL_DIR/oona")"
  form="$(status_str "$status" launcherForm)"
  if [ -z "$status" ]; then
    warn "could not ask the installed CLI about the background service — set it up with: oona service install && oona service start"
  elif status_is "$status" installed true && [ "$form" = "desktop" ]; then
    ok "the OonaCode desktop app owns the background host on this machine — left as it is; it updates with the app"
  elif status_is "$status" installed true && [ "$form" != "cli" ]; then
    warn "a background host is registered by another launcher ($(status_str "$status" command)) — left as it is. Take it over with: oona service install --replace"
  else
    steps=""
    if ! status_is "$status" installed true || status_is "$status" matches false; then steps="install"; fi
    status_is "$status" running true && steps="$steps stop"
    steps="$steps start"
    for s in $steps; do
      if ! "$INSTALL_DIR/oona" service "$s"; then
        # `stop` is best-effort: the `start` after it is what matters.
        [ "$s" = "stop" ] && continue
        warn "could not $s the background service automatically — see: oona service status"
        break
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------------------------
# 8. the desktop app (install.ps1's Update-DesktopApp, for Linux)
# ---------------------------------------------------------------------------------------------
# One command installs everything, as on Windows (owner, 2026-09-26: "the one-line installer also
# installs the desktop app on Linux"): the AppImage is the per-user install, no root, like the
# per-user NSIS one. A .deb/.rpm install belongs to its package manager. A machine with no desktop
# session gets no app unless --desktop asks for it. The menu entry is the one the app itself writes
# (xdg-desktop-entry.ts: same text, same X-OonaCode-AppImage marker), so the app keeps it current.

# A desktop session on this machine — also when this runs over ssh, where DISPLAY is unset.
graphical_session() {
  { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; } && return 0
  ls "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/wayland-* >/dev/null 2>&1 && return 0
  command -v loginctl >/dev/null 2>&1 || return 1
  for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$(id -un)" '$3 == u {print $1}'); do
    case "$(loginctl show-session "$sid" -p Type --value 2>/dev/null)" in x11|wayland) return 0 ;; esac
  done
  return 1
}
# An Exec= argument (the app's execArg): bare when it needs no quoting, else double-quoted.
exec_arg() {
  case "$1" in
    *[!A-Za-z0-9_@%+=:,./-]*) printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"`$]/\\&/g')" ;;
    *) printf '%s' "$1" ;;
  esac
}

apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
app_entry="$apps_dir/oonacode.desktop"
app_current=""
if [ -f "$app_entry" ] && grep -qx 'X-OonaCode-AppImage=true' "$app_entry"; then
  app_current="$(sed -n 's/^TryExec=//p' "$app_entry" | head -1 | sed 's/\\\\/\\/g')"
  [ -f "$app_current" ] || app_current=""
fi
app_have=""
[ -n "$app_current" ] && app_have="$(sed -n 's/^X-AppImage-Version=//p' "$app_entry" | head -1)"
app_target="${app_current:-$HOME/Applications/OonaCode.AppImage}"
app_file="OonaCode-$VERSION-x86_64.AppImage"
app_sum=""
[ -f "$TMP/SHA256SUMS.txt" ] &&
  app_sum="$(awk -v n="$app_file" '$2 == n || $2 == "*" n {print $1; exit}' "$TMP/SHA256SUMS.txt")"
DESKTOP_STARTED=0

# macOS: OonaCode.app, per user, in ~/Applications — no sudo, as the AppImage is on Linux. From
# --app-zip, else the zip of the same build beside --archive (mac-builder.sh's output and dist\mac
# hold both), else the release's OonaCode-<v>-mac-<arch>.zip. Unpacked beside the old app and
# swapped in, so a failed unpack leaves the old one as it was.
mac_desktop_step() {
  local apps="$HOME/Applications" app="$HOME/Applications/OonaCode.app" zip="" want="" sums="" have=""
  local zip_name="OonaCode-$VERSION-mac-$ARCH.zip" found="" n=0 c stage quarantined=0
  if [ -d "$app" ]; then
    have="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)"
  fi
  if [ "$NO_DESKTOP" = "1" ]; then
    step "8/8 desktop app (skipped: --no-desktop)"
    [ -n "$have" ] && note "OonaCode.app v$have stays in ~/Applications"
    return 0
  fi
  if [ -n "$APP_ZIP" ]; then
    [ -f "$APP_ZIP" ] || die "--app-zip $APP_ZIP does not exist"
    zip="$APP_ZIP"
  elif [ -n "$ARCHIVE" ]; then
    for c in "$(dirname "$ARCHIVE")"/OonaCode-*-mac-"$ARCH".zip; do
      [ -f "$c" ] || continue
      found="$c"
      n=$((n + 1))
    done
    if [ "$n" -gt 1 ]; then
      step "8/8 desktop app (skipped: several OonaCode-*-mac-$ARCH.zip beside the archive — name one with --app-zip)"
      return 0
    elif [ "$n" -eq 0 ]; then
      step "8/8 desktop app (skipped: --archive installs the terminal half; --app-zip FILE installs the app too)"
      return 0
    fi
    zip="$found"
  fi
  if [ -n "$zip" ]; then
    # A local zip: checked against the SHA256SUMS.txt beside it, when that names it.
    sums="$(dirname "$zip")/SHA256SUMS.txt"
    [ -f "$sums" ] && want="$(awk -v n="$(basename "$zip")" '$2 == n || $2 == "*" n {print $1; exit}' "$sums")"
    step "8/8 installing the desktop app from $(basename "$zip")${have:+ (replacing v$have)}"
    if [ -n "$want" ]; then
      [ "$(sha256_of "$zip")" = "$want" ] || die "$zip does not match the SHA256SUMS.txt beside it — the desktop app was not touched"
      ok "checksum verified against $sums"
    fi
  else
    [ -f "$TMP/SHA256SUMS.txt" ] &&
      want="$(awk -v n="$zip_name" '$2 == n || $2 == "*" n {print $1; exit}' "$TMP/SHA256SUMS.txt")"
    if [ -z "$want" ]; then
      step "8/8 desktop app"
      note "release v$VERSION ships no $zip_name — terminal-only install"
      return 0
    fi
    if [ "$have" = "$VERSION" ]; then
      step "8/8 desktop app"
      ok "already at v$VERSION (~/Applications/OonaCode.app)"
      return 0
    fi
    if [ -n "$have" ]; then step "8/8 updating the desktop app v$have -> v$VERSION"
    else step "8/8 installing the desktop app v$VERSION (--no-desktop skips it)"
    fi
    if ! enough_space "$TMP" $(( 200 * 1024 )); then
      warn "$(space_message "$TMP" $(( 200 * 1024 )) "the desktop app download") — the desktop app was not installed"
      return 0
    fi
    if ! fetch "$base/$zip_name" "$TMP/$zip_name"; then
      warn "could not download $base/$zip_name — the desktop app was not installed; run this again later"
      return 0
    fi
    [ "$(sha256_of "$TMP/$zip_name")" = "$want" ] ||
      die "checksum mismatch for $zip_name — the download is corrupt or tampered with; the desktop app was not touched"
    ok "checksum verified"
    zip="$TMP/$zip_name"
  fi
  # The .app is ~300 MB unpacked, and the old one stays until the new one is complete.
  mkdir -p "$apps"
  if ! enough_space "$apps" $(( 450 * 1024 )); then
    warn "$(space_message "$apps" $(( 450 * 1024 )) "the desktop app") — the desktop app was not installed"
    return 0
  fi
  stage="$apps/.OonaCode-install-$$"
  rm -rf "$stage"
  mkdir -p "$stage"
  # ditto, as Finder and Squirrel.Mac unpack an app: symlinks inside the frameworks, modes and
  # extended attributes kept.
  if ! ditto -x -k "$zip" "$stage" || [ ! -x "$stage/OonaCode.app/Contents/MacOS/OonaCode" ]; then
    rm -rf "$stage"
    warn "could not unpack $(basename "$zip") into an OonaCode.app — the desktop app was not installed"
    return 0
  fi
  xattr -p com.apple.quarantine "$stage/OonaCode.app" >/dev/null 2>&1 && quarantined=1
  # Never swap a bundle something runs from: the app reads its UI files from disk on every request
  # and starts helpers on demand, and the background host may run from it too (the app's own
  # LaunchAgent, `OonaCode --service`). Both are stopped first and come back after the swap. The
  # app's update button runs this script DETACHED for exactly this reason: it is quit here and
  # reopened below.
  local app_was_open=0 service_from_app=0 pid
  if [ -d "$app" ] && [ "$form" = "desktop" ] && status_is "$status" running true; then
    service_from_app=1
    note "stopping the background host, which runs from the app, for the swap"
    "$INSTALL_DIR/oona" service stop >/dev/null 2>&1 || warn "could not stop the background host — see: oona service status"
  fi
  for pid in $(mac_app_gui_pids "$app"); do
    if [ "$app_was_open" = "0" ]; then
      # The app locks the device when it closes, and that lock outlives a restart; this quit is the
      # update's, so the app is told (packages/desktop/src/main/update-quit.ts reads and spends it).
      mkdir -p "$HOME_DIR/host" && : > "$HOME_DIR/host/quit-for-update" 2>/dev/null || true
    fi
    app_was_open=1
    kill -TERM "$pid" 2>/dev/null || true
  done
  if [ "$app_was_open" = "1" ]; then
    note "quitting OonaCode for the update — it reopens when the new version is in place"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      [ -z "$(mac_app_gui_pids "$app")" ] && break
      sleep 1
    done
    if [ -n "$(mac_app_gui_pids "$app")" ]; then
      rm -rf "$stage"
      warn "OonaCode did not quit within 20 s — the desktop app was not updated; quit it and run this again"
      [ "$service_from_app" = "1" ] && "$INSTALL_DIR/oona" service start >/dev/null 2>&1
      return 0
    fi
  fi
  [ -d "$app" ] && mv "$app" "$stage/OonaCode.app.old"
  mv "$stage/OonaCode.app" "$app"
  rm -rf "$stage"
  ok "installed at ~/Applications/OonaCode.app (ad-hoc signed; no Apple Developer ID yet)"
  if [ "$service_from_app" = "1" ]; then
    "$INSTALL_DIR/oona" service start >/dev/null 2>&1 && ok "background host started again from the new app" ||
      warn "could not start the background host again — run: oona service start"
  fi
  if [ "$quarantined" = "1" ]; then
    # Not removed here: the quarantine is macOS's record that the zip came from the internet, and
    # the person decides. The app is not signed yet, so Gatekeeper asks before its first start.
    warn "the zip came from a download, so macOS will ask before OonaCode first opens (it is not signed yet): System Settings → Privacy & Security → Open Anyway"
  elif [ "$app_was_open" = "1" ]; then
    open "$app" >/dev/null 2>&1 && DESKTOP_STARTED=1 && ok "reopened OonaCode"
  elif [ -z "$have" ] && [ "$(stat -f %Su /dev/console 2>/dev/null)" = "$(id -un)" ]; then
    # A fresh install opens the app, as install.ps1 does — when this user is the one logged in at
    # the Mac's screen (/dev/console), which is also true over ssh; `open` reaches that session.
    # An ssh variable is no test: on the owner's Mac, aicontrol's own shell carried an old
    # SSH_CONNECTION, and the app was not opened for a person sitting at the Mac.
    open "$app" >/dev/null 2>&1 && DESKTOP_STARTED=1 && ok "started OonaCode"
  fi
  return 0
}

# The pids of OonaCode.app's own window process — not its `--service` supervisor (the app's
# LaunchAgent), and not its helpers, which go with it. `-a`: macOS's pgrep leaves out its own
# ANCESTORS by default, and when the app's update button runs this script the app IS one (app ->
# oona update -> bash -> pgrep, detached but still its child) — so without it the running app was
# never found, and its bundle was swapped under it (measured on the owner's Mac, 2026-10-03).
# Darwin-only: procps' -a on Linux means something else.
mac_app_gui_pids() {
  local bin="$1/Contents/MacOS/OonaCode" pid args
  for pid in $(pgrep -a -f "$bin" 2>/dev/null || true); do
    args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
    case "$args" in
      "$bin"|"$bin "*) case " $args " in *" --service "*) ;; *) printf '%s\n' "$pid" ;; esac ;;
    esac
  done
}

if [ "$PLATFORM" = "darwin" ]; then
  mac_desktop_step
elif [ "$NO_DESKTOP" = "1" ]; then
  step "8/8 desktop app (skipped: --no-desktop)"
  [ -n "$app_current" ] && note "the app at $app_current updates itself"
elif [ -x /opt/OonaCode/oonacode ]; then
  step "8/8 desktop app"
  ok "installed from a .deb/.rpm (/opt/OonaCode) — your package manager updates it"
elif [ -n "$ARCHIVE" ]; then
  step "8/8 desktop app (skipped: --archive installs the terminal half)"
elif [ -z "$app_current" ] && [ "$FORCE_DESKTOP" = "0" ] && ! graphical_session; then
  step "8/8 desktop app (skipped: no desktop session on this machine — --desktop installs it anyway)"
elif [ "$app_have" = "$VERSION" ]; then
  step "8/8 desktop app"
  ok "already at v$VERSION ($app_target)"
elif [ -z "$app_sum" ]; then
  step "8/8 desktop app"
  note "release v$VERSION ships no $app_file — terminal-only install"
else
  if [ -z "$app_current" ]; then
    step "8/8 installing the desktop app v$VERSION (--no-desktop skips it)"
  else
    step "8/8 updating the desktop app v${app_have:-?} -> v$VERSION"
  fi
  # Downloaded beside it, then renamed over it: a running app keeps the file it started from, the
  # next start is the new one (the AppImage updater replaces it the same way), and the ~120 MB
  # never passes through $TMP. The old file stays until the rename, so the new one must fit whole.
  app_new="$app_target.new"
  app_short=""
  mkdir -p "$(dirname "$app_target")"
  enough_space "$app_target" $(( 160 * 1024 )) ||
    app_short="$(space_message "$app_target" $(( 160 * 1024 )) "the desktop app")"
  if [ -n "$app_short" ]; then
    warn "$app_short — the desktop app was not ${app_current:+updated}${app_current:-installed}; free some space and run this again"
  elif ! fetch "$base/$app_file" "$app_new"; then
    rm -f "$app_new"
    warn "could not download $base/$app_file — the desktop app was not ${app_current:+updated}${app_current:-installed}; run this again later"
  elif [ "$(sha256_of "$app_new")" != "$app_sum" ]; then
    rm -f "$app_new"
    die "checksum mismatch for $app_file — the download is corrupt or tampered with; the desktop app was not touched"
  else
    ok "checksum verified"
    chmod 0755 "$app_new"
    mv -f "$app_new" "$app_target"
    mkdir -p "$apps_dir"
    if [ -f "$INSTALL_DIR/oonacode.png" ]; then
      icons_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
      mkdir -p "$icons_dir" && cp -f "$INSTALL_DIR/oonacode.png" "$icons_dir/oonacode.png"
    fi
    if [ -f "$app_entry" ] && ! grep -qx 'X-OonaCode-AppImage=true' "$app_entry"; then
      warn "$app_entry is not one OonaCode wrote — left as it is"
    else
      printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=OonaCode' \
        'Comment=The Claude Code engine, any provider — a remote-capable coding agent' \
        "Exec=$(exec_arg "$app_target") %U" "TryExec=$(printf '%s' "$app_target" | sed 's/\\/\\\\/g')" \
        'Icon=oonacode' 'Terminal=false' 'Categories=Development;Utility;' 'StartupWMClass=OonaCode' \
        'StartupNotify=true' "X-AppImage-Version=$VERSION" 'X-OonaCode-AppImage=true' > "$app_entry"
      chmod 0644 "$app_entry"
      update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
    fi
    ok "installed at $app_target"
    if [ -n "$app_current" ]; then
      pgrep -f "$app_target" >/dev/null 2>&1 && note "OonaCode is running — restart it to use v$VERSION"
    elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
      # A fresh install opens the app, as install.ps1 does; never from a session with no display.
      (setsid "$app_target" >/dev/null 2>&1 < /dev/null &) && DESKTOP_STARTED=1 && ok "started OonaCode"
    fi
  fi
fi

# ---------------------------------------------------------------------------------------------
# what protects the keys at rest (docs/linux-port.md "The login gate on Linux", docs/remote-unlock.md)
# ---------------------------------------------------------------------------------------------
# The host keeps its token key — and, since 2026-09-05, the "keep me unlocked" wrap of the vault's
# master key — behind the first of: systemd-creds (root, or per-user credentials on systemd ≥ 256),
# the login keyring through `secret-tool`, a 0600 file beside the database. The last is a supported
# shape that protects less than it looks (a copy of the home directory carries the key with it), and
# it is where an ordinary desktop user lands when secret-tool is missing. So SUGGEST the package,
# by family, and never sudo on the user's behalf. `oona doctor` says which rung is in force.
keystore_advice() {
  desktop=0
  if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ] || [ -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]; then
    desktop=1
  fi
  if [ "$desktop" = "1" ]; then
    if command -v secret-tool >/dev/null 2>&1; then
      ok "keys at rest: systemd-creds where your systemd allows it, else your login keyring (secret-tool is installed) — oona doctor says which"
      return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then pkg="sudo apt install libsecret-tools"
    elif command -v dnf >/dev/null 2>&1; then pkg="sudo dnf install libsecret"
    elif command -v pacman >/dev/null 2>&1; then pkg="sudo pacman -S libsecret"
    elif command -v zypper >/dev/null 2>&1; then pkg="sudo zypper install libsecret-tools"
    else pkg="install the package that provides secret-tool (libsecret)"
    fi
    warn "keys at rest: no secret-tool, so the host's key stays a 0600 file beside its database — a copy of your home directory carries it. To keep it in your login keyring instead:"
    warn "  $pkg    # then: oona service stop && oona service start"
    return 0
  fi
  # Headless: no keyring will ever answer here; only systemd-creds can bind the key to the machine.
  # No systemctl at all (a plain container) is fine: `|| true` keeps `set -e -o pipefail` from ending the
  # installer here, after every step has already run (found 2026-10-07 on Debian 12 / Ubuntu 24.04 containers).
  sysv="$({ systemctl --version 2>/dev/null || true; } | sed -n '1s/^systemd \([0-9][0-9]*\).*/\1/p')"
  if [ "$(id -u)" = "0" ] && command -v systemd-creds >/dev/null 2>&1; then
    note "keys at rest: no desktop session; as root the host can use systemd-creds (machine-bound) — oona doctor confirms which rung is in force"
  else
    note "keys at rest: no desktop session, so the host's key is a 0600 file beside its database (a copy of your home directory carries it) — systemd ≥ 256 (this box: ${sysv:-none}) or a root-run host could bind it to the machine instead; oona doctor says which is in force"
  fi
}
# The HOST chose what holds its key, and its doctor says which (`token-key-protection`): systemd-creds
# is tried before the keyring, so a guess from here said "login keyring" on machines where
# systemd-creds held it (docs/linux-parity-plan.md bug 10). The guess stays only for an install
# with no running host to ask.
at_rest=""
if [ "$NO_SERVICE" = "0" ]; then
  at_rest="$("$INSTALL_DIR/oona" doctor 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -m1 'tokens at rest' || true)"
  at_rest="${at_rest#*tokens at rest — }"
fi
if [ -n "$at_rest" ]; then
  note "keys at rest: $at_rest"
elif [ "$PLATFORM" = "darwin" ]; then
  # macOS: the login keychain (key-protectors.ts), which answers the login session's processes —
  # the LaunchAgent's host — and not an ssh session's. Nothing to install for it.
  note "keys at rest: the host keeps its key in your login keychain — oona doctor says what holds it"
else
  keystore_advice
fi

step "done"
ok "OonaCode ${installed_version:-$VERSION} is installed."
if [ "$PLATFORM" = "darwin" ]; then
  [ "$DESKTOP_STARTED" = "1" ] || [ ! -d "$HOME/Applications/OonaCode.app" ] ||
    note "the desktop app:  ~/Applications/OonaCode.app (Spotlight finds it as OonaCode)"
else
  [ "$DESKTOP_STARTED" = "1" ] || note "on your desktop:  search \"OonaCode\" in your applications menu"
fi
# A script run by `curl … | bash` cannot change the PATH of the terminal that ran it.
[ "$PATH_NOT_LIVE" = "1" ] && note "this terminal does not see ~/.local/bin yet: open a new terminal, or run  export PATH=\"\$HOME/.local/bin:\$PATH\""
note "next:  oona login          # sign in (an account is required to run a turn)"
note "       oona                # the terminal app"
note "       oona doctor         # check this install"
note "       oona service status # the background host"
note "uninstall:  oona uninstall   (or: curl -fsSL $ORIGIN/install.sh | bash -s -- --uninstall)"
