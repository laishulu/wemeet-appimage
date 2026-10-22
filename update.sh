#!/usr/bin/env bash
set -euo pipefail

# 1. Map required commands to their corresponding Nix package names
declare -A BIN_PKG_MAP=(
  [curl]="curl"
  [jq]="jq"
  [python3]="python3"
  [nix-hash]="nix"
  [nix-prefetch-url]="nix"
  [nix-prefetch-git]="nix-prefetch-git"
)

REQUIRED_BINS=("${!BIN_PKG_MAP[@]}")
MISSING_PKGS=()

for bin in "${REQUIRED_BINS[@]}"; do
  if ! command -v "$bin" &>/dev/null; then
    pkg="${BIN_PKG_MAP[$bin]}"
    if [[ ! " ${MISSING_PKGS[*]:-} " =~ [[:space:]]${pkg}[[:space:]] ]]; then
      MISSING_PKGS+=("$pkg")
    fi
  fi
done

# 2. Re-enter via nix-shell if dependencies are missing (guarded against recursive loops)
if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
  if [ "${IN_NIX_SHELL_UPDATER:-}" = "1" ]; then
    echo "Error: Still missing dependencies inside nix-shell: ${MISSING_PKGS[*]}" >&2
    exit 1
  fi

  echo "==> Missing dependencies: ${MISSING_PKGS[*]}"
  echo "==> Entering temporary nix-shell environment..."
  exec env IN_NIX_SHELL_UPDATER=1 nix-shell -p "${MISSING_PKGS[@]}" --run "$(printf '%q ' "$0" "$@")"
fi

NIX_FILE="${1:-flake.nix}"
VERSION_FILE="version.txt"

if [ ! -f "$NIX_FILE" ]; then
  echo "Error: Nix file not found: $NIX_FILE" >&2
  exit 1
fi

echo "==> 1. Fetching AUR PKGBUILD for wemeet-bin..."
AUR_DIR=$(mktemp -d)
trap 'rm -rf "$AUR_DIR"' EXIT

curl -sSL "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=wemeet-bin" -o "$AUR_DIR/PKGBUILD"

echo "==> 2. Parsing PKGBUILD variables..."
PARSED_VARS=$(bash -c '
  set -a
  source "'"$AUR_DIR/PKGBUILD"'" 2>/dev/null || true

  deb_url=""
  for item in "${source_x86_64[@]:-}" "${source[@]:-}"; do
    candidate="${item#*::}"
    if [[ "$candidate" =~ ^https?:// ]] && [[ "$candidate" == *.deb* || "$candidate" == *wemeet* ]]; then
      deb_url="$candidate"
      break
    fi
  done

  # Strip query parameters if present
  deb_url="${deb_url%%\?*}"

  sha512="${sha512sums_x86_64[0]:-${sha512sums[0]:-}}"
  sha256="${sha256sums_x86_64[0]:-${sha256sums[0]:-}}"

  echo "PKGVER=${pkgver:-}"
  echo "DEB_URL=${deb_url:-}"
  echo "SHA512=${sha512:-}"
  echo "SHA256=${sha256:-}"
')

eval "$PARSED_VARS"

if [ -z "$DEB_URL" ] || [ -z "$PKGVER" ]; then
  echo "Error: Failed to parse package version or deb URL from AUR PKGBUILD." >&2
  exit 1
fi

echo "Version : $PKGVER"
echo "Base URL: $DEB_URL"

# Check if already up to date before overwriting version.txt
if [ -f "$VERSION_FILE" ] && [ "$(cat "$VERSION_FILE")" = "$PKGVER" ]; then
  echo "==> Package is already up to date ($PKGVER)."
fi

echo "==> 3. Fetching latest AUR Git revision and hash for libwemeetwrap..."
AUR_GIT_JSON=$(nix-prefetch-git --url "https://aur.archlinux.org/wemeet-bin.git" --rev "HEAD" --quiet)
AUR_REV=$(echo "$AUR_GIT_JSON" | jq -r '.rev')
WRAP_HASH=$(echo "$AUR_GIT_JSON" | jq -r '.hash')

echo "AUR Commit: $AUR_REV"
echo "Wrap Hash : $WRAP_HASH"

echo "==> 4. Calculating SRI hash for deb package..."
if [[ "${SHA512:-}" =~ ^[a-fA-F0-9]{128}$ ]]; then
  DEB_HASH=$(nix-hash --type sha512 --to-sri "$SHA512")
elif [[ "${SHA256:-}" =~ ^[a-fA-F0-9]{64}$ ]]; then
  DEB_HASH=$(nix-hash --type sha256 --to-sri "$SHA256")
else
  echo "Checksum not found in PKGBUILD, prefetching deb URL..."
  RAW_SHA256=$(nix-prefetch-url --type sha256 "$DEB_URL")
  DEB_HASH=$(nix-hash --type sha256 --to-sri "$RAW_SHA256")
fi

echo "Deb SRI Hash: $DEB_HASH"

echo "==> 5. Fetching latest release appimagetool and runtime SRI hashes..."
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/latest/download/appimagetool-x86_64.AppImage"
RAW_APPIMAGETOOL_SHA256=$(nix-prefetch-url --type sha256 "$APPIMAGETOOL_URL")
APPIMAGETOOL_HASH=$(nix-hash --type sha256 --to-sri "$RAW_APPIMAGETOOL_SHA256")
echo "appimagetool SRI Hash: $APPIMAGETOOL_HASH"

RUNTIME_URL="https://github.com/AppImage/type2-runtime/releases/latest/download/runtime-x86_64"
RAW_RUNTIME_SHA256=$(nix-prefetch-url --type sha256 "$RUNTIME_URL")
RUNTIME_HASH=$(nix-hash --type sha256 --to-sri "$RAW_RUNTIME_SHA256")
echo "runtime SRI Hash     : $RUNTIME_HASH"

echo "==> 6. Updating $NIX_FILE..."
python3 -c "
import re

with open('$NIX_FILE', 'r') as f:
    content = f.read()

# 1. Update wemeetConfig version
content = re.sub(
    r'(wemeetConfig\s*=\s*\{[\s\S]*?version\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$PKGVER\g<2>',
    content
)

# 2. Update wemeetConfig url
content = re.sub(
    r'(wemeetConfig\s*=\s*\{[\s\S]*?url\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$DEB_URL\g<2>',
    content
)

# 3. Update wemeetConfig hash
content = re.sub(
    r'(wemeetConfig\s*=\s*\{[\s\S]*?hash\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$DEB_HASH\g<2>',
    content
)

# 4. Update libwemeetwrap git rev & hash
content = re.sub(
    r'(libwemeetwrap\s*=\s*pkgs\.stdenv\.mkDerivation\s*\{[\s\S]*?rev\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$AUR_REV\g<2>',
    content
)
content = re.sub(
    r'(libwemeetwrap\s*=\s*pkgs\.stdenv\.mkDerivation\s*\{[\s\S]*?hash\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$WRAP_HASH\g<2>',
    content
)

# 5. Update appimagetool url & hash
content = re.sub(
    r'(appimagetool\s*=\s*pkgs\.fetchurl\s*\{[\s\S]*?url\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$APPIMAGETOOL_URL\g<2>',
    content
)
content = re.sub(
    r'(appimagetool\s*=\s*pkgs\.fetchurl\s*\{[\s\S]*?hash\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$APPIMAGETOOL_HASH\g<2>',
    content
)

# 6. Update appimageRuntime url & hash
content = re.sub(
    r'(appimageRuntime\s*=\s*pkgs\.fetchurl\s*\{[\s\S]*?url\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$RUNTIME_URL\g<2>',
    content
)
content = re.sub(
    r'(appimageRuntime\s*=\s*pkgs\.fetchurl\s*\{[\s\S]*?hash\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$RUNTIME_HASH\g<2>',
    content
)

with open('$NIX_FILE', 'w') as f:
    f.write(content)
"

echo "==> 7. Updating latest.txt and version.txt..."
date -u -Iseconds > latest.txt
echo "$PKGVER" > "$VERSION_FILE"

echo "==> Successfully updated $NIX_FILE!"
