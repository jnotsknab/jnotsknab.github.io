#!/usr/bin/env bash
set -euo pipefail

# Mux-Swarm Linux/macOS Installer
# Recommended usage:
#   curl -fsSL https://www.muxswarm.dev/install.sh | bash
#
# Optional direct usage:
#   ./install.sh
#   ./install.sh --version v1.0.1
#   ./install.sh --force
#   ./install.sh --asset-name mux-swarm-linux-x64.tar.gz
#
# Expected release assets (auto-detected by OS/arch unless overridden):
#   mux-swarm-linux-x64.tar.gz
#   mux-swarm-linux-arm64.tar.gz
#   mux-swarm-osx-x64.tar.gz
#   mux-swarm-osx-arm64.tar.gz
#
# Supported archive formats:
#   .tar.gz, .tgz, .zip

VERSION="latest"
REPO_OWNER="jnotsknab"
REPO_NAME="mux-swarm"
ASSET_NAME=""
INSTALL_DIR=""
FORCE="0"
COMMAND_NAME="mux-swarm"
ALIAS_NAME="ms"
BIN_DIR="$HOME/.local/bin"
TMP_ROOT=""
PLATFORM=""
ARCH=""

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; }

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --version <tag>        Release tag to install (default: latest)
  --repo-owner <owner>   GitHub repo owner (default: ${REPO_OWNER})
  --repo-name <name>     GitHub repo name (default: ${REPO_NAME})
  --asset-name <file>    Override release asset name
  --install-dir <dir>    Override install directory
  --force                Replace existing install payload
  -h, --help             Show this help
USAGE
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_directory() {
  mkdir -p "$1"
}

get_download_url() {
  local owner="$1" repo="$2" version="$3" asset="$4"
  if [[ "$version" == "latest" ]]; then
    printf 'https://github.com/%s/%s/releases/latest/download/%s\n' "$owner" "$repo" "$asset"
  else
    printf 'https://github.com/%s/%s/releases/download/%s/%s\n' "$owner" "$repo" "$version" "$asset"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        VERSION="${2:?missing value for --version}"
        shift 2
        ;;
      --repo-owner)
        REPO_OWNER="${2:?missing value for --repo-owner}"
        shift 2
        ;;
      --repo-name)
        REPO_NAME="${2:?missing value for --repo-name}"
        shift 2
        ;;
      --asset-name)
        ASSET_NAME="${2:?missing value for --asset-name}"
        shift 2
        ;;
      --install-dir)
        INSTALL_DIR="${2:?missing value for --install-dir}"
        shift 2
        ;;
      --force)
        FORCE="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

detect_platform() {
  local os_raw arch_raw
  os_raw="$(uname -s)"
  arch_raw="$(uname -m)"

  case "$os_raw" in
    Linux) PLATFORM="linux" ;;
    Darwin) PLATFORM="osx" ;;
    *) fail "This installer supports Linux and macOS only. Detected: $os_raw"; exit 1 ;;
  esac

  case "$arch_raw" in
    x86_64|amd64) ARCH="x64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) fail "Unsupported architecture: $arch_raw"; exit 1 ;;
  esac

  if [[ -z "$INSTALL_DIR" ]]; then
    if [[ "$PLATFORM" == "osx" ]]; then
      INSTALL_DIR="$HOME/Library/Application Support/Mux-Swarm"
    else
      INSTALL_DIR="$HOME/.local/share/Mux-Swarm"
    fi
  fi
}

detect_asset_name() {
  if [[ -n "$ASSET_NAME" ]]; then
    printf '%s\n' "$ASSET_NAME"
    return
  fi

  printf 'mux-swarm-%s-%s.tar.gz\n' "$PLATFORM" "$ARCH"
}

download_file() {
  local url="$1" out="$2"

  if command_exists curl; then
    curl -fL --retry 3 --connect-timeout 15 -o "$out" "$url"
    return
  fi

  if command_exists wget; then
    wget -O "$out" "$url"
    return
  fi

  fail 'Neither curl nor wget is installed.'
  exit 1
}

extract_archive() {
  local archive="$1" destination="$2"

  case "$archive" in
    *.tar.gz|*.tgz)
      tar -xzf "$archive" -C "$destination"
      ;;
    *.zip)
      if ! command_exists unzip; then
        fail 'unzip is required to extract .zip assets.'
        exit 1
      fi
      unzip -q "$archive" -d "$destination"
      ;;
    *)
      fail "Unsupported archive format: $archive"
      exit 1
      ;;
  esac
}

get_payload_root() {
  local path="$1"
  local item_count only_dir

  item_count="$(find "$path" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  if [[ "$item_count" == "1" ]]; then
    only_dir="$(find "$path" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
    if [[ -n "$only_dir" ]]; then
      printf '%s\n' "$only_dir"
      return
    fi
  fi

  printf '%s\n' "$path"
}

find_executable() {
  local root="$1"
  local candidate
  local -a preferred_candidates=(
    "$root/MuxSwarm"
    "$root/Mux-Swarm"
    "$root/mux-swarm"
    "$root/Qwe"
    "$root/qwe"
  )
  local -a matches=()
  local path name lower score best_score=-1 best_match=""

  for candidate in "${preferred_candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  while IFS= read -r -d '' path; do
    [[ -f "$path" ]] || continue
    [[ -x "$path" ]] || continue

    name="$(basename "$path")"
    lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

    case "$lower" in
      *.dll|*.dylib|*.so|*.a|*.o|*.pdb|*.json|*.txt|*.md|*.yml|*.yaml|*.toml|*.xml|*.sh|*.ps1|*.bat|*.cmd|*.exe.config)
        continue
        ;;
    esac

    if [[ "$path" == *"/Runtime/"* || "$path" == *"/Sessions/"* || "$path" == *"/Skills/"* || "$path" == *"/Prompts/"* || "$path" == *"/Configs/"* ]]; then
      continue
    fi

    score=0
    [[ "$path" == "$root/"* ]] && score=$((score + 5))
    [[ "$lower" == *mux* ]] && score=$((score + 20))
    [[ "$lower" == *swarm* ]] && score=$((score + 20))
    [[ "$lower" == qwe* ]] && score=$((score + 8))
    [[ "$lower" != *.* ]] && score=$((score + 5))
    [[ "$path" == "$root/publish/"* ]] && score=$((score + 10))

    if (( score > best_score )); then
      best_score=$score
      best_match="$path"
    fi

    matches+=("$path")
  done < <(find "$root" -type f -perm -111 -print0 2>/dev/null)

  if [[ -n "$best_match" ]]; then
    printf '%s\n' "$best_match"
    return
  fi

  if [[ ${#matches[@]} -gt 0 ]]; then
    printf '%s\n' "${matches[0]}"
  fi
}

remove_install_payload_but_preserve_data() {
  local target_dir="$1"
  [[ -d "$target_dir" ]] || return 0

  shopt -s dotglob nullglob
  local item base
  for item in "$target_dir"/*; do
    base="$(basename "$item")"
    if [[ "$base" == 'Sessions' ]]; then
      info 'Preserving Sessions'
      continue
    fi
    rm -rf "$item"
  done
  shopt -u dotglob nullglob
}

copy_payload() {
  local source_dir="$1" target_dir="$2"
  ensure_directory "$target_dir"

  shopt -s dotglob nullglob
  local item base dst
  for item in "$source_dir"/*; do
    base="$(basename "$item")"
    dst="$target_dir/$base"

    if [[ "$base" == 'Sessions' && -e "$dst" ]]; then
      info 'Preserving existing Sessions directory'
      continue
    fi

    rm -rf "$dst"
    cp -R "$item" "$dst"
  done
  shopt -u dotglob nullglob
}

write_shell_shim_block() {
  local install_root="$1" exe_name="$2"
  cat <<SHIM
# >>> Mux-Swarm shim >>>
mux-swarm() {
  local install_dir="$install_root"
  local exe_path="\$install_dir/$exe_name"

  if [[ ! -d "\$install_dir" ]]; then
    printf 'Mux-Swarm install directory not found: %s\n' "\$install_dir" >&2
    return 1
  fi

  if [[ ! -f "\$exe_path" ]]; then
    printf 'Mux-Swarm executable not found: %s\n' "\$exe_path" >&2
    return 1
  fi

  (
    cd "\$install_dir"
    "\$exe_path" "\$@"
  )
}

alias ms='mux-swarm'
# <<< Mux-Swarm shim <<<
SHIM
}

ensure_path_line_in_profile() {
  local profile_path="$1"
  local export_line='export PATH="$HOME/.local/bin:$PATH"'

  ensure_directory "$(dirname "$profile_path")"
  [[ -f "$profile_path" ]] || : > "$profile_path"

  if ! grep -Fqs "$export_line" "$profile_path"; then
    printf '\n%s\n' "$export_line" >> "$profile_path"
    ok "Ensured PATH update in $profile_path"
  fi
}

install_shell_shim_into_profile() {
  local profile_path="$1" install_root="$2" exe_name="$3"
  local start_marker="# >>> Mux-Swarm shim >>>"
  local end_marker="# <<< Mux-Swarm shim <<<"
  local tmp

  ensure_directory "$(dirname "$profile_path")"
  [[ -f "$profile_path" ]] || : > "$profile_path"
  tmp="$(mktemp)"

  awk -v start="$start_marker" -v end="$end_marker" '
    $0 == start { skipping=1; next }
    $0 == end { skipping=0; next }
    !skipping { print }
  ' "$profile_path" > "$tmp"

  mv "$tmp" "$profile_path"
  {
    printf '\n'
    write_shell_shim_block "$install_root" "$exe_name"
    printf '\n'
  } >> "$profile_path"

  ok "Updated shell shim in $profile_path"
}

install_profile_shims() {
  local install_root="$1" exe_name="$2"
  local profiles=()
  local profile_path

  if [[ -n "${BASH_VERSION:-}" || -f "$HOME/.bashrc" ]]; then
    profiles+=("$HOME/.bashrc")
  fi
  if [[ -n "${ZSH_VERSION:-}" || -f "$HOME/.zshrc" ]]; then
    profiles+=("$HOME/.zshrc")
  fi
  if [[ ${#profiles[@]} -eq 0 ]]; then
    profiles+=("$HOME/.profile")
  fi

  for profile_path in "${profiles[@]}"; do
    ensure_path_line_in_profile "$profile_path"
    install_shell_shim_into_profile "$profile_path" "$install_root" "$exe_name"
  done
}

write_launch_wrapper() {
  local install_root="$1" exe_name="$2"
  local wrapper_path="$BIN_DIR/$COMMAND_NAME"
  local alias_path="$BIN_DIR/$ALIAS_NAME"

  ensure_directory "$BIN_DIR"

  cat > "$wrapper_path" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR="$install_root"
EXE_PATH="\$INSTALL_DIR/$exe_name"

if [[ ! -d "\$INSTALL_DIR" ]]; then
  printf 'Mux-Swarm install directory not found: %s\n' "\$INSTALL_DIR" >&2
  exit 1
fi

if [[ ! -f "\$EXE_PATH" ]]; then
  printf 'Mux-Swarm executable not found: %s\n' "\$EXE_PATH" >&2
  exit 1
fi

cd "\$INSTALL_DIR"
exec "\$EXE_PATH" "\$@"
WRAP

  chmod +x "$wrapper_path"
  ln -sf "$wrapper_path" "$alias_path"
  ok "Installed launch wrapper at $wrapper_path"
}

write_uninstall_script() {
  local install_root="$1"
  local script_path="$install_root/uninstall.sh"

  cat > "$script_path" <<UNINSTALL
#!/usr/bin/env bash
set -euo pipefail

KEEP_SESSIONS="0"

while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --keep-sessions)
      KEEP_SESSIONS="1"
      shift
      ;;
    -h|--help)
      cat <<HELP
Usage: ./uninstall.sh [--keep-sessions]
HELP
      exit 0
      ;;
    *)
      printf '[FAIL] Unknown argument: %s\n' "\$1" >&2
      exit 1
      ;;
  esac
done

INSTALL_DIR="$install_root"
START_MARKER='# >>> Mux-Swarm shim >>>'
END_MARKER='# <<< Mux-Swarm shim <<<'
PROFILES=("\$HOME/.bashrc" "\$HOME/.zshrc" "\$HOME/.profile")

printf '[INFO] Removing shell shims if present...\n'
for profile in "\${PROFILES[@]}"; do
  [[ -f "\$profile" ]] || continue
  tmp="\$(mktemp)"
  awk -v start="\$START_MARKER" -v end="\$END_MARKER" '
    \$0 == start { skipping=1; next }
    \$0 == end { skipping=0; next }
    !skipping { print }
  ' "\$profile" > "\$tmp"
  mv "\$tmp" "\$profile"
done

rm -f "\$HOME/.local/bin/mux-swarm" "\$HOME/.local/bin/ms"

if [[ -d "\$INSTALL_DIR" ]]; then
  if [[ "\$KEEP_SESSIONS" == '1' && -d "\$INSTALL_DIR/Sessions" ]]; then
    printf '[INFO] Preserving Sessions directory...\n'
    shopt -s dotglob nullglob
    for item in "\$INSTALL_DIR"/*; do
      [[ "\$(basename "\$item")" == 'Sessions' ]] && continue
      rm -rf "\$item"
    done
    shopt -u dotglob nullglob
  else
    printf '[INFO] Removing install directory...\n'
    rm -rf "\$INSTALL_DIR"
  fi
fi

printf '[ OK ] Mux-Swarm uninstalled.\n'
UNINSTALL

  chmod +x "$script_path"
  ok "Wrote uninstall script to $script_path"
}

cleanup() {
  if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    rm -rf "$TMP_ROOT" || warn "Could not fully clean temporary files at $TMP_ROOT"
  fi
}

main() {
  local asset download_url archive_path extract_path payload_root exe_path_in_payload exe_name final_exe

  parse_args "$@"
  detect_platform

  asset="$(detect_asset_name)"
  download_url="$(get_download_url "$REPO_OWNER" "$REPO_NAME" "$VERSION" "$asset")"

  TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t mux-swarm-install)"
  archive_path="$TMP_ROOT/$asset"
  extract_path="$TMP_ROOT/extract"

  ensure_directory "$extract_path"
  ensure_directory "$INSTALL_DIR"

  info "Detected platform: $PLATFORM"
  info "Detected architecture: $ARCH"
  info "Downloading $download_url"
  download_file "$download_url" "$archive_path"
  ok 'Download complete'

  info 'Extracting archive'
  extract_archive "$archive_path" "$extract_path"

  payload_root="$(get_payload_root "$extract_path")"
  exe_path_in_payload="$(find_executable "$payload_root")"

  if [[ -z "$exe_path_in_payload" ]]; then
    fail 'No executable found in release archive.'
    exit 1
  fi

  exe_name="$(basename "$exe_path_in_payload")"

  if [[ "$FORCE" == '1' ]]; then
    warn 'Force enabled; replacing existing install payload'
  else
    info 'Updating install payload in place'
  fi

  remove_install_payload_but_preserve_data "$INSTALL_DIR"

  info "Copying files to $INSTALL_DIR"
  copy_payload "$payload_root" "$INSTALL_DIR"

  final_exe="$INSTALL_DIR/$exe_name"
  if [[ ! -f "$final_exe" ]]; then
    fail "Install completed, but executable not found at $final_exe"
    exit 1
  fi

  chmod +x "$final_exe" || true
  write_launch_wrapper "$INSTALL_DIR" "$exe_name"
  install_profile_shims "$INSTALL_DIR" "$exe_name"
  write_uninstall_script "$INSTALL_DIR"

  printf '\n'
  ok 'Mux-Swarm installed successfully'
  printf 'Install directory: %s\n' "$INSTALL_DIR"
  printf 'Executable:       %s\n' "$exe_name"
  printf 'Shell cmd:        %s\n' "$COMMAND_NAME"
  printf 'Alias:            %s\n' "$ALIAS_NAME"
  printf '\n'
  printf 'Next steps:\n'
  printf '  1. Open a new terminal, or run: source ~/.bashrc or source ~/.zshrc\n'
  printf '  2. Run: %s\n' "$COMMAND_NAME"
  printf '\n'

  case "$exe_name" in
    Qwe|qwe)
      warn "The shipped binary is still named $exe_name. Once you rename it to Mux-Swarm, the installer will pick it up automatically."
      ;;
  esac
}

trap cleanup EXIT
main "$@"
