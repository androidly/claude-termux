#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly CLAUDE_PACKAGE_NAME="@anthropic-ai/claude-code"
readonly CLAUDE_PACKAGE_VERSION="${CLAUDE_CODE_VERSION:-latest}"
readonly PREFIX_DIR="${PREFIX:-/data/data/com.termux/files/usr}"
readonly HOST_CLAUDE_PATH="$PREFIX_DIR/bin/claude"
readonly CLAUDE_PKG_DIR="$PREFIX_DIR/lib/node_modules/@anthropic-ai/claude-code"
readonly CLAUDE_ARCH_PKG_NAME="@anthropic-ai/claude-code-linux-arm64"
readonly CLAUDE_ARCH_PKG_DIR="$PREFIX_DIR/lib/node_modules/$CLAUDE_ARCH_PKG_NAME"
# Resolved by install_claude_package() after locating the real glibc ELF.
CLAUDE_BINARY_PATH=""
readonly BACKUP_DIR="$HOME/.claude/tmp"
readonly WRAPPER_MARKER="# claude-code-termux-glibc-wrapper"

readonly C_BOLD_BLUE="\033[1;34m"
readonly C_BOLD_GREEN="\033[1;32m"
readonly C_BOLD_YELLOW="\033[1;33m"
readonly C_BOLD_RED="\033[1;31m"
readonly C_RESET="\033[0m"

info()    { printf '%b[INFO]%b %s\n' "$C_BOLD_BLUE"   "$C_RESET" "$*"; }
success() { printf '%b[ OK ]%b %s\n' "$C_BOLD_GREEN"  "$C_RESET" "$*"; }
warn()    { printf '%b[WARN]%b %s\n' "$C_BOLD_YELLOW" "$C_RESET" "$*" >&2; }
die()     { printf '%b[ERR ]%b %s\n' "$C_BOLD_RED"    "$C_RESET" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage:
  bash $SCRIPT_NAME

What it does (glibc-runner mode, no proot):
  1. Installs glibc-repo, refreshes apt metadata, installs glibc-runner.
  2. Installs nodejs-lts + npm in Termux (if missing).
  3. npm installs ${CLAUDE_PACKAGE_NAME} globally, forcing the
     linux-arm64 (glibc) optional dependency via --os/--cpu overrides.
  4. If install.cjs skipped placing the binary (Termux reports
     process.platform='android'), copies it from the optional dep.
  5. Replaces \$PREFIX/bin/claude with a grun wrapper that runs
     the glibc ELF directly on Termux — no proot, no syscall emulation.

Environment overrides:
  CLAUDE_CODE_VERSION   npm package version/tag, default: ${CLAUDE_PACKAGE_VERSION}

Notes:
  - glibc-runner injects glibc via LD_LIBRARY_PATH; kernel calls are native.
  - glibc-repo is an apt repo add-on package; it drops sources into
    \$PREFIX/etc/apt/sources.list.d/ so glibc-runner becomes visible after
    an apt update. Docs: https://github.com/termux-pacman/glibc-packages/wiki
EOF
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ELF magic = 7f 45 4c 46; e_machine at offset 18 = 0xb7 for EM_AARCH64.
is_valid_aarch64_elf() {
    local f="$1"
    [ -f "$f" ] || return 1
    local magic machine
    magic=$(od -An -tx1 -N4    "$f" 2>/dev/null | tr -d ' \n')
    [ "$magic" = "7f454c46" ] || return 1
    machine=$(od -An -tx1 -j18 -N1 "$f" 2>/dev/null | tr -d ' \n')
    [ "$machine" = "b7" ]
}

# Search $CLAUDE_ARCH_PKG_DIR for the real Claude ELF and set CLAUDE_BINARY_PATH.
find_arch_binary() {
    local candidate
    for candidate in \
        "$CLAUDE_ARCH_PKG_DIR/bin/claude" \
        "$CLAUDE_ARCH_PKG_DIR/bin/claude.exe"; do
        if is_valid_aarch64_elf "$candidate"; then
            CLAUDE_BINARY_PATH="$candidate"
            return 0
        fi
    done
    # Fallback: scan the whole arch-pkg dir for any file that's a valid
    # aarch64 ELF > 10 MB (the real binary is hundreds of megabytes).
    while IFS= read -r candidate; do
        if is_valid_aarch64_elf "$candidate"; then
            CLAUDE_BINARY_PATH="$candidate"
            return 0
        fi
    done < <(find "$CLAUDE_ARCH_PKG_DIR" -type f -size +10M 2>/dev/null)
    return 1
}

require_termux() {
    [ -d "$PREFIX_DIR" ] || die "This script must run in Termux."
    command_exists pkg   || die "pkg not found. This script must run in Termux."
    # Refuse to run inside an existing proot (avoids installing into Debian by mistake).
    if [ -r /proc/1/status ] && grep -q 'TracerPid:.*[1-9]' /proc/1/status 2>/dev/null; then
        warn "Detected non-zero TracerPid on PID 1 — looks like a proot session."
        warn "Run this script from a plain Termux shell, not from inside proot-distro."
    fi
}

ensure_termux_package() {
    local package_name="$1"
    if dpkg -s "$package_name" >/dev/null 2>&1; then
        success "Termux package already installed: $package_name"
        return 0
    fi
    info "Installing Termux package: $package_name"
    pkg install -y "$package_name"
    success "Installed Termux package: $package_name"
}

ensure_glibc_runner() {
    # glibc-runner lives in the glibc-packages repo, not tur-repo.
    # Installing glibc-repo drops an apt sources list; we must refresh
    # metadata before glibc-runner becomes resolvable.
    ensure_termux_package "glibc-repo"

    if ! apt-cache show glibc-runner >/dev/null 2>&1; then
        info "Refreshing apt metadata so glibc-repo becomes visible"
        pkg update -y || apt-get update -y || true
    fi

    ensure_termux_package "glibc-runner"
    command_exists grun || die "grun not found after installing glibc-runner."
}

ensure_nodejs() {
    if command_exists node && command_exists npm; then
        success "Termux node present: $(node --version), npm $(npm --version)"
        return 0
    fi
    # nodejs-lts and nodejs conflict; prefer LTS if neither installed.
    if dpkg -s nodejs >/dev/null 2>&1; then
        success "nodejs already installed"
    else
        ensure_termux_package "nodejs-lts"
    fi
}

install_claude_package() {
    local pkg_spec="$CLAUDE_PACKAGE_NAME"
    if [ "$CLAUDE_PACKAGE_VERSION" != "latest" ]; then
        pkg_spec="${CLAUDE_PACKAGE_NAME}@${CLAUDE_PACKAGE_VERSION}"
    fi

    info "Installing ${pkg_spec} (main package; will produce a stub at bin/claude.exe on Termux)"
    npm install -g --force --foreground-scripts "$pkg_spec"

    # npm on Termux has process.platform='android', so every linux/*/win32
    # optionalDependency is filtered out during resolution — regardless of
    # --os/--cpu flags, which don't reliably propagate to optional-dep
    # selection across npm versions. Pull the arch-specific tarball
    # explicitly, pinned to the main package's version so binary and
    # runtime agree.
    local main_version
    main_version=$(node -p "require('$CLAUDE_PKG_DIR/package.json').version" 2>/dev/null) \
        || die "Failed to read installed version from $CLAUDE_PKG_DIR/package.json"

    local arch_spec="${CLAUDE_ARCH_PKG_NAME}@${main_version}"
    info "Installing ${arch_spec} (explicit, bypasses platform filter)"
    npm install -g --force --foreground-scripts "$arch_spec"

    find_arch_binary || die "No valid aarch64 ELF found under $CLAUDE_ARCH_PKG_DIR. \
The arch package may not have unpacked correctly; inspect with: \
ls -la $CLAUDE_ARCH_PKG_DIR"

    success "Claude native binary: $CLAUDE_BINARY_PATH ($(stat -c %s "$CLAUDE_BINARY_PATH" 2>/dev/null || echo '?') bytes)"
}

backup_existing_launcher() {
    mkdir -p "$BACKUP_DIR"
    [ -e "$HOST_CLAUDE_PATH" ] || return 0
    if grep -Fq "$WRAPPER_MARKER" "$HOST_CLAUDE_PATH" 2>/dev/null; then
        success "glibc-runner wrapper already in place"
        return 0
    fi
    local backup_path="$BACKUP_DIR/claude.host-backup.$(date +%Y%m%d_%H%M%S)"
    cp -P "$HOST_CLAUDE_PATH" "$backup_path"
    success "Backed up existing launcher to $backup_path"
}

install_host_wrapper() {
    local tmp_wrapper
    tmp_wrapper="$(mktemp "${TMPDIR:-/tmp}/claude-grun.XXXXXX")"

    cat >"$tmp_wrapper" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
$WRAPPER_MARKER
exec grun "$CLAUDE_BINARY_PATH" "\$@"
EOF

    chmod 755 "$tmp_wrapper"
    # npm install usually creates a symlink at HOST_CLAUDE_PATH pointing at
    # claude.exe; replace it with our shim so Termux doesn't try to exec the
    # glibc binary directly (which bionic's linker cannot load).
    rm -f "$HOST_CLAUDE_PATH"
    mv "$tmp_wrapper" "$HOST_CLAUDE_PATH"
    chmod 755 "$HOST_CLAUDE_PATH"
    success "Installed Termux launcher: $HOST_CLAUDE_PATH"
}

verify_install() {
    info "Verifying binary via grun"
    grun "$CLAUDE_BINARY_PATH" --version
    info "Verifying Termux launcher"
    "$HOST_CLAUDE_PATH" --version
    success "Claude Code setup completed (glibc-runner mode)"
}

main() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        usage
        exit 0
    fi

    require_termux
    ensure_glibc_runner
    ensure_nodejs
    install_claude_package
    backup_existing_launcher
    install_host_wrapper
    verify_install

    cat <<EOF

Run Claude Code with:
  claude

Configuration:
  mode:     glibc-runner (no proot)
  binary:   $CLAUDE_BINARY_PATH
  launcher: $HOST_CLAUDE_PATH

If you had the old proot-based install, you can reclaim space with:
  proot-distro remove debian
  pkg uninstall proot-distro

Troubleshooting:
  - If subprocess errors mention libc/ld.so: the binary is loading Termux
    bionic libs via inherited LD_LIBRARY_PATH. Consider patchelf'ing the
    binary's RPATH directly instead of using grun (see glibc-runner docs).
  - If npm skipped the linux-arm64 optional dep, rerun with:
      CLAUDE_CODE_VERSION=<pinned-version> bash $SCRIPT_NAME
EOF
}

main "$@"
