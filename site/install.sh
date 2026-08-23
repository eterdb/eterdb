#!/bin/sh
# EterDB CLI installer.
#
#   curl -fsSL https://eterdb.com/install.sh | sh
#
# Downloads the right prebuilt `eter` binary from the latest GitHub Release,
# verifies its checksum, and installs it. Overridable via env:
#   ETER_VERSION      release tag to install (default: latest, e.g. v0.1.0)
#   ETER_INSTALL_DIR  where to put the binary (default: /usr/local/bin, else ~/.local/bin)
#   ETER_INSTALL_REPO owner/repo to pull releases from (default: eterdb/eterdb)
set -eu

REPO="${ETER_INSTALL_REPO:-eterdb/eterdb}"
BINARY="eter"

info() { printf '%s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need uname
need tar

# --- pick a downloader -------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
	dl() { curl -fsSL "$1"; }
	dlout() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
	dl() { wget -qO- "$1"; }
	dlout() { wget -qO "$2" "$1"; }
else
	die "need curl or wget"
fi

# --- detect os/arch ----------------------------------------------------------
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
linux | darwin) ;;
*) die "unsupported OS: $os (use the container images or build from source)" ;;
esac

arch=$(uname -m)
case "$arch" in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) die "unsupported architecture: $arch" ;;
esac

# --- resolve version ---------------------------------------------------------
tag="${ETER_VERSION:-}"
if [ -z "$tag" ]; then
	info "resolving latest release of $REPO ..."
	tag=$(dl "https://api.github.com/repos/$REPO/releases/latest" |
		grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
	[ -n "$tag" ] || die "could not resolve the latest release tag"
fi
version=${tag#v} # goreleaser strips the leading v for asset names

asset="${BINARY}_${version}_${os}_${arch}.tar.gz"
# ETER_INSTALL_BASEURL overrides the release-asset base (for mirrors / testing).
base="${ETER_INSTALL_BASEURL:-https://github.com/$REPO/releases/download/$tag}"
info "installing $BINARY $tag ($os/$arch)"

# --- download + verify -------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dlout "$base/$asset" "$tmp/$asset" || die "download failed: $base/$asset"

if dlout "$base/checksums.txt" "$tmp/checksums.txt" 2>/dev/null; then
	want=$(grep " $asset\$" "$tmp/checksums.txt" | awk '{print $1}')
	if [ -n "$want" ]; then
		if command -v sha256sum >/dev/null 2>&1; then
			got=$(sha256sum "$tmp/$asset" | awk '{print $1}')
		elif command -v shasum >/dev/null 2>&1; then
			got=$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')
		fi
		if [ -n "${got:-}" ] && [ "$got" != "$want" ]; then
			die "checksum mismatch for $asset (expected $want, got $got)"
		fi
		info "checksum ok"
	fi
else
	info "warning: checksums.txt not found, skipping verification"
fi

tar -xzf "$tmp/$asset" -C "$tmp"
[ -f "$tmp/$BINARY" ] || die "archive did not contain $BINARY"
chmod +x "$tmp/$BINARY"

# --- choose an install dir ---------------------------------------------------
dir="${ETER_INSTALL_DIR:-}"
if [ -z "$dir" ]; then
	if [ -w /usr/local/bin ]; then
		dir=/usr/local/bin
	elif [ "$(id -u)" = 0 ]; then
		dir=/usr/local/bin
	else
		dir="$HOME/.local/bin"
	fi
fi
mkdir -p "$dir"

if mv "$tmp/$BINARY" "$dir/$BINARY" 2>/dev/null; then
	:
elif command -v sudo >/dev/null 2>&1; then
	info "elevating to write $dir (sudo)"
	sudo mv "$tmp/$BINARY" "$dir/$BINARY"
else
	die "cannot write to $dir, set ETER_INSTALL_DIR to a writable path"
fi

info "installed $dir/$BINARY"
case ":$PATH:" in
*":$dir:"*) ;;
*) info "note: $dir is not on your PATH, add it, e.g. export PATH=\"$dir:\$PATH\"" ;;
esac
info "run '$BINARY doctor' to check your setup."
