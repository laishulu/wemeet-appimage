#!/usr/bin/env bash
set -euo pipefail

# 1. Map required commands to their corresponding Nix package names
declare -A BIN_PKG_MAP=(
  [curl]="curl"
  [jq]="jq"
  [python3]="python3"
  [nix-hash]="nix"
  [nix-prefetch-git]="nix-prefetch-git"
)

REQUIRED_BINS=("${!BIN_PKG_MAP[@]}")
MISSING_PKGS=()

for bin in "${REQUIRED_BINS[@]}"; do
  if ! command -v "$bin" &>/dev/null; then
    pkg="${BIN_PKG_MAP[$bin]}"
    # Avoid adding duplicate packages
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
# Safely source variables in an isolated subshell
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

echo "==> 3. Updating version.txt..."
echo "$PKGVER" > "$VERSION_FILE"

echo "==> 4. Fetching AUR Git revision and hash..."
AUR_GIT_JSON=$(nix-prefetch-git --url "https://aur.archlinux.org/wemeet-bin.git" --rev "HEAD" --quiet)
AUR_REV=$(echo "$AUR_GIT_JSON" | jq -r '.rev')
WRAP_HASH=$(echo "$AUR_GIT_JSON" | jq -r '.hash')

echo "AUR Commit: $AUR_REV"
echo "Wrap Hash : $WRAP_HASH"

echo "==> 5. Calculating SRI hash for deb package..."
if [[ "${SHA512:-}" =~ ^[a-fA-F0-9]{128}$ ]]; then
  DEB_HASH=$(nix-hash --type sha512 --to-sri "$SHA512")
elif [[ "${SHA256:-}" =~ ^[a-fA-F0-9]{64}$ ]]; then
  DEB_HASH=$(nix-hash --type sha256 --to-sri "$SHA256")
else
  echo "Checksum not found in PKGBUILD, prefetching deb URL..."
  RAW_SHA256=$(nix-prefetch-url --type sha256 "$DEB_URL")
  DEB_HASH=$(nix-hash --type sha256 --to-sri "$RAW_SHA256")
fi

echo "Deb Hash  : $DEB_HASH"

echo "==> 6. Updating $NIX_FILE..."
python3 -c "
import re

with open('$NIX_FILE', 'r') as f:
    content = f.read()

# 1. Update libwemeetwrap derivation
content = re.sub(
    r'(libwemeetwrap\s*=\s*pkgs\.stdenv\.mkDerivation\s*\{[\s\S]*?version\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$PKGVER\2',
    content
)
content = re.sub(
    r'(url\s*=\s*\"https://aur\.archlinux\.org/wemeet-bin\.git\";\s*rev\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$AUR_REV\2',
    content
)
content = re.sub(
    r'(url\s*=\s*\"https://aur\.archlinux\.org/wemeet-bin\.git\";[\s\S]*?hash\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$WRAP_HASH\2',
    content
)

# 2. Update wemeet derivation
content = re.sub(
    r'(wemeet\s*=\s*pkgs\.stdenv\.mkDerivation\s*\{[\s\S]*?version\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$PKGVER\2',
    content
)
content = re.sub(
    r'(wemeet\s*=\s*pkgs\.stdenv\.mkDerivation\s*\{[\s\S]*?src\s*=\s*pkgs\.fetchurl\s*\{[\s\S]*?url\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$DEB_URL\2',
    content
)
content = re.sub(
    r'(wemeet\s*=\s*pkgs\.stdenv\.mkDerivation\s*\{[\s\S]*?src\s*=\s*pkgs\.fetchurl\s*\{[\s\S]*?hash\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$DEB_HASH\2',
    content
)

with open('$NIX_FILE', 'w') as f:
    f.write(content)
"

echo "==> 7. Updating latest.txt..."
date -u -Iseconds > latest.txt

echo "==> Successfully updated $NIX_FILE!"
