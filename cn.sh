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
# 在 install_claude_package() 找到真正的 glibc ELF 后赋值。
CLAUDE_BINARY_PATH=""
readonly BACKUP_DIR="$HOME/.claude/tmp"
readonly WRAPPER_MARKER="# claude-code-termux-glibc-wrapper"

readonly C_BOLD_BLUE="\033[1;34m"
readonly C_BOLD_GREEN="\033[1;32m"
readonly C_BOLD_YELLOW="\033[1;33m"
readonly C_BOLD_RED="\033[1;31m"
readonly C_RESET="\033[0m"

info()    { printf '%b[信息]%b %s\n' "$C_BOLD_BLUE"   "$C_RESET" "$*"; }
success() { printf '%b[成功]%b %s\n' "$C_BOLD_GREEN"  "$C_RESET" "$*"; }
warn()    { printf '%b[警告]%b %s\n' "$C_BOLD_YELLOW" "$C_RESET" "$*" >&2; }
die()     { printf '%b[错误]%b %s\n' "$C_BOLD_RED"    "$C_RESET" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
用法：
  bash $SCRIPT_NAME

这个脚本会做什么（glibc-runner 模式，不用 proot）：
  1. 安装 glibc-repo，刷新 apt 元数据，然后安装 glibc-runner。
  2. 在 Termux 里安装 nodejs-lts 和 npm（如果还没装）。
  3. 全局安装 ${CLAUDE_PACKAGE_NAME}，并通过 --os/--cpu 指定
     linux-arm64（glibc）可选依赖。
  4. 如果 install.cjs 因为 Termux 显示 process.platform='android'
     而跳过二进制文件，就从可选依赖包里补上。
  5. 用 grun 包装器替换 \$PREFIX/bin/claude，让 Termux 直接运行
     glibc ELF；不需要 proot，也不做系统调用模拟。

环境变量覆盖：
  CLAUDE_CODE_VERSION   npm 包版本或标签，默认：${CLAUDE_PACKAGE_VERSION}

说明：
  - glibc-runner 通过 LD_LIBRARY_PATH 注入 glibc；内核调用仍是原生执行。
  - glibc-repo 是 apt 仓库扩展包；它会把源写到
    \$PREFIX/etc/apt/sources.list.d/，apt update 后就能看到 glibc-runner。
    文档：https://github.com/termux-pacman/glibc-packages/wiki
EOF
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ELF 魔数 = 7f 45 4c 46；偏移 18 处的 e_machine = 0xb7 表示 EM_AARCH64。
is_valid_aarch64_elf() {
    local f="$1"
    [ -f "$f" ] || return 1
    local magic machine
    magic=$(od -An -tx1 -N4    "$f" 2>/dev/null | tr -d ' \n')
    [ "$magic" = "7f454c46" ] || return 1
    machine=$(od -An -tx1 -j18 -N1 "$f" 2>/dev/null | tr -d ' \n')
    [ "$machine" = "b7" ]
}

# 在 $CLAUDE_ARCH_PKG_DIR 里查找真正的 Claude ELF，并设置 CLAUDE_BINARY_PATH。
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
    # 兜底：扫描整个架构包目录，找有效且大于 10 MB 的 aarch64 ELF
    # 文件（真正的二进制文件通常有几百 MB）。
    while IFS= read -r candidate; do
        if is_valid_aarch64_elf "$candidate"; then
            CLAUDE_BINARY_PATH="$candidate"
            return 0
        fi
    done < <(find "$CLAUDE_ARCH_PKG_DIR" -type f -size +10M 2>/dev/null)
    return 1
}

require_termux() {
    [ -d "$PREFIX_DIR" ] || die "这个脚本必须在 Termux 里运行。"
    command_exists pkg   || die "找不到 pkg。这个脚本必须在 Termux 里运行。"
    # 不建议在已有 proot 里运行，避免误装到 Debian 之类的环境。
    if [ -r /proc/1/status ] && grep -q 'TracerPid:.*[1-9]' /proc/1/status 2>/dev/null; then
        warn "检测到 PID 1 的 TracerPid 非 0，看起来像是在 proot 会话里。"
        warn "请在普通 Termux shell 里运行，不要在 proot-distro 里面运行。"
    fi
}

ensure_termux_package() {
    local package_name="$1"
    if dpkg -s "$package_name" >/dev/null 2>&1; then
        success "Termux 包已安装：$package_name"
        return 0
    fi
    info "正在安装 Termux 包：$package_name"
    pkg install -y "$package_name"
    success "Termux 包安装完成：$package_name"
}

ensure_glibc_runner() {
    # glibc-runner 在 glibc-packages 仓库里，不在 tur-repo 里。
    # 安装 glibc-repo 会写入 apt 源列表；必须刷新元数据后才能解析 glibc-runner。
    ensure_termux_package "glibc-repo"

    if ! apt-cache show glibc-runner >/dev/null 2>&1; then
        info "正在刷新 apt 元数据，让 glibc-repo 生效"
        pkg update -y || apt-get update -y || true
    fi

    ensure_termux_package "glibc-runner"
    command_exists grun || die "安装 glibc-runner 后仍找不到 grun。"
}

ensure_nodejs() {
    if command_exists node && command_exists npm; then
        success "Termux 里已存在 node：$(node --version)，npm：$(npm --version)"
        return 0
    fi
    # nodejs-lts 和 nodejs 冲突；如果两个都没装，优先装 LTS。
    if dpkg -s nodejs >/dev/null 2>&1; then
        success "nodejs 已安装"
    else
        ensure_termux_package "nodejs-lts"
    fi
}

install_claude_package() {
    local pkg_spec="$CLAUDE_PACKAGE_NAME"
    if [ "$CLAUDE_PACKAGE_VERSION" != "latest" ]; then
        pkg_spec="${CLAUDE_PACKAGE_NAME}@${CLAUDE_PACKAGE_VERSION}"
    fi

    info "正在安装 ${pkg_spec}（主包；在 Termux 上会生成 bin/claude.exe 占位文件）"
    npm install -g --force --foreground-scripts "$pkg_spec"

    # Termux 上 npm 的 process.platform='android'，所以解析时会过滤掉
    # linux/*/win32 optionalDependency。--os/--cpu 在不同 npm 版本里
    # 不一定能可靠传递到可选依赖选择逻辑，所以这里显式拉取架构包，
    # 并固定到主包版本，保证二进制和运行时代码匹配。
    local main_version
    main_version=$(node -p "require('$CLAUDE_PKG_DIR/package.json').version" 2>/dev/null) \
        || die "无法从 $CLAUDE_PKG_DIR/package.json 读取已安装版本"

    local arch_spec="${CLAUDE_ARCH_PKG_NAME}@${main_version}"
    info "正在安装 ${arch_spec}（显式安装，绕过平台过滤）"
    npm install -g --force --foreground-scripts "$arch_spec"

    find_arch_binary || die "在 $CLAUDE_ARCH_PKG_DIR 下没有找到有效的 aarch64 ELF。\
架构包可能没有正确解包；可用下面命令检查：\
ls -la $CLAUDE_ARCH_PKG_DIR"

    success "Claude 原生二进制文件：$CLAUDE_BINARY_PATH（$(stat -c %s "$CLAUDE_BINARY_PATH" 2>/dev/null || echo '?') 字节）"
}

backup_existing_launcher() {
    mkdir -p "$BACKUP_DIR"
    [ -e "$HOST_CLAUDE_PATH" ] || return 0
    if grep -Fq "$WRAPPER_MARKER" "$HOST_CLAUDE_PATH" 2>/dev/null; then
        success "glibc-runner 包装器已存在"
        return 0
    fi
    local backup_path="$BACKUP_DIR/claude.host-backup.$(date +%Y%m%d_%H%M%S)"
    cp -P "$HOST_CLAUDE_PATH" "$backup_path"
    success "已备份现有启动器到：$backup_path"
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
    # npm install 通常会在 HOST_CLAUDE_PATH 创建指向 claude.exe 的符号链接；
    # 这里替换成我们的 shim，避免 Termux 直接执行 glibc 二进制文件
    # （bionic 链接器无法加载它）。
    rm -f "$HOST_CLAUDE_PATH"
    mv "$tmp_wrapper" "$HOST_CLAUDE_PATH"
    chmod 755 "$HOST_CLAUDE_PATH"
    success "Termux 启动器安装完成：$HOST_CLAUDE_PATH"
}

verify_install() {
    info "正在通过 grun 验证二进制文件"
    grun "$CLAUDE_BINARY_PATH" --version
    info "正在验证 Termux 启动器"
    "$HOST_CLAUDE_PATH" --version
    success "Claude Code 安装配置完成（glibc-runner 模式）"
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

运行 Claude Code：
  claude

当前配置：
  模式：      glibc-runner（不用 proot）
  二进制：    $CLAUDE_BINARY_PATH
  启动器：    $HOST_CLAUDE_PATH

如果你之前装过旧版 proot 方案，可以用下面命令回收空间：
  proot-distro remove debian
  pkg uninstall proot-distro

排错：
  - 如果子进程报错里提到 libc/ld.so：说明二进制文件通过继承的
    LD_LIBRARY_PATH 加载到了 Termux 的 bionic 库。可以考虑直接用
    patchelf 修改二进制文件的 RPATH，而不是使用 grun（见 glibc-runner 文档）。
  - 如果 npm 跳过了 linux-arm64 可选依赖，可重新运行：
      CLAUDE_CODE_VERSION=<pinned-version> bash $SCRIPT_NAME
EOF
}

main "$@"
