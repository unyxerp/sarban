#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
#  Sarban Linux — Stage 2 Bootstrap (v3, fast)
#
#  Downloaded by the floppy after network is up. Flow:
#    1. Create /ramdisk (tmpfs, 80% of RAM)
#    2. Download full static BusyBox — now we have 350 commands
#    3. In parallel: install Alpine toolchain AND fetch sources
#    4. Compile Dropbear SSH → start sshd (notify 50%)
#    5. Compile Links browser
#    6. Clean up toolchain+sources, free RAM (notify 100%)
#
#  Speed choices:
#    • No BusyBox source rebuild — the download in step 2 is already a
#      full static BusyBox, re-compiling it was pure redundancy.
#    • Source tarballs fetch in background while the (much larger)
#      toolchain downloads, so the net download time is max() not sum().
#    • Slimmer apk set: build-base covers gcc/make/libc-dev already;
#      perl and linux-headers were not needed by dropbear or links.
#    • Dropbear builds only `dropbear` + `dropbearkey` (no dbclient,
#      scp, MULTI, SCPPROGRESS) — cuts ~40% off dropbear link time.
# ═══════════════════════════════════════════════════════════════════
set -e

RAMDISK="/ramdisk"
SRCDIR="/ramdisk/src"
BUILDROOT="/ramdisk/root"
TOOLCHAIN="/ramdisk/toolchain"
NCPU=1

# Try to get more cores via sysfs (nproc may not be in stage1 busybox)
if [ -r /sys/devices/system/cpu/online ]; then
    cpurange=$(cat /sys/devices/system/cpu/online)
    # Count CPUs from the range (e.g., "0-3" => 4)
    case "$cpurange" in
        *-*)
            hi=${cpurange##*-}
            lo=${cpurange%%-*}
            NCPU=$((hi - lo + 1))
            ;;
        *)
            NCPU=1
            ;;
    esac
fi

ALPINE_VER="3.20"
ALPINE_ARCH="x86_64"
ALPINE_MIRROR="http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}"
ALPINE_MAIN="${ALPINE_MIRROR}/main/${ALPINE_ARCH}"

# Pre-built full static BusyBox. Single file, no apk extraction needed.
FULL_BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"

DROPBEAR_VER="2024.86"
DROPBEAR_URL="https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VER}.tar.bz2"
LINKS_VER="2.30"
LINKS_URL="http://links.twibright.com/download/links-${LINKS_VER}.tar.gz"

notify() {
    msg="$1"; title="$2"; color="${3:-36}"
    {
        printf '\n\033[1;%sm' "$color"
        printf '  ╔══════════════════════════════════════════════════╗\n'
        printf '  ║  %-48s ║\n' "SARBAN LINUX — $title"
        printf '  ║  %-48s ║\n' "$msg"
        printf '  ╚══════════════════════════════════════════════════╝\n\033[0m\n'
    } > /dev/console 2>/dev/null
}

info() { echo "[+] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[X] $*"; notify "$*" "BUILD FAILED" "31"; exit 1; }

# ═════════════════════════════════════════════════════════════════
#  PHASE 0: Create ramdisk, download full BusyBox
#  After this phase, we have 350+ commands. Everything else is easy.
# ═════════════════════════════════════════════════════════════════
phase0_ramdisk_and_full_busybox() {
    info "Creating ramdisk (80% of RAM)..."
    # /proc/meminfo parsing with just head + test (no awk)
    total_kb=$(head -n 1 /proc/meminfo 2>/dev/null)
    # total_kb looks like "MemTotal:       4023932 kB"
    # Strip everything non-digit
    total_kb=$(echo "$total_kb" | grep -o '[0-9][0-9]*')
    [ -z "$total_kb" ] && total_kb=1048576  # 1GB fallback
    ramdisk_kb=$((total_kb * 80 / 100))

    mkdir -p "$RAMDISK"
    mount -t tmpfs -o size=${ramdisk_kb}k tmpfs "$RAMDISK" 2>/dev/null || :
    mkdir -p "$SRCDIR" "$BUILDROOT" "$BUILDROOT/bin"

    info "Downloading full static BusyBox (~1MB)..."
    if ! wget -q -O "$BUILDROOT/bin/busybox" "$FULL_BUSYBOX_URL"; then
        die "Failed to download full BusyBox from $FULL_BUSYBOX_URL"
    fi
    chmod +x "$BUILDROOT/bin/busybox"

    # Verify it runs
    if ! "$BUILDROOT/bin/busybox" --help > /dev/null 2>&1; then
        die "Downloaded BusyBox binary doesn't execute"
    fi

    # Install applet symlinks
    mkdir -p "$BUILDROOT/sbin" "$BUILDROOT/usr/bin" "$BUILDROOT/usr/sbin"
    "$BUILDROOT/bin/busybox" --install -s "$BUILDROOT/bin" 2>/dev/null
    "$BUILDROOT/bin/busybox" --install -s "$BUILDROOT/sbin" 2>/dev/null
    "$BUILDROOT/bin/busybox" --install -s "$BUILDROOT/usr/bin" 2>/dev/null
    "$BUILDROOT/bin/busybox" --install -s "$BUILDROOT/usr/sbin" 2>/dev/null

    # Add to PATH so rest of stage2 has access to nproc, awk, find, etc.
    export PATH="$BUILDROOT/bin:$BUILDROOT/sbin:$BUILDROOT/usr/bin:$BUILDROOT/usr/sbin:$PATH"
    NCPU=$(nproc 2>/dev/null || echo 1)

    ncmds=$(ls "$BUILDROOT/bin/" "$BUILDROOT/sbin/" "$BUILDROOT/usr/bin/" "$BUILDROOT/usr/sbin/" 2>/dev/null | sort -u | wc -l)
    info "Full BusyBox ready: $ncmds commands, $NCPU CPUs"

    # Explicitly create rest of buildroot layout now that mkdir -p works everywhere
    mkdir -p "$BUILDROOT/etc"
    mkdir -p "$BUILDROOT/etc/dropbear"
    mkdir -p "$BUILDROOT/root"
    mkdir -p "$BUILDROOT/tmp"
    mkdir -p "$BUILDROOT/var/log"
    mkdir -p "$BUILDROOT/var/run"
    mkdir -p "$BUILDROOT/dev"
    mkdir -p "$BUILDROOT/proc"
    mkdir -p "$BUILDROOT/sys"
    mkdir -p "$BUILDROOT/run"
    mkdir -p "$BUILDROOT/usr/share/udhcpc"
}

fetch() {
    url="$1"; dest="$2"
    [ -f "$dest" ] && [ "$(stat -c%s "$dest" 2>/dev/null)" -ge 1000 ] && return 0
    info "Fetching $(basename "$dest")..."
    if ! wget -q -O "$dest" "$url" 2>/dev/null; then
        http_url=$(echo "$url" | sed 's|^https://|http://|')
        [ "$http_url" != "$url" ] && wget -q -O "$dest" "$http_url" 2>/dev/null || :
    fi
    if [ ! -f "$dest" ] || [ "$(stat -c%s "$dest" 2>/dev/null)" -lt 1000 ]; then
        rm -f "$dest"
        die "Download failed: $url"
    fi
}

# Kick off a download in the background; pid appended to BG_PIDS.
BG_PIDS=""
fetch_bg() {
    (fetch "$1" "$2") &
    BG_PIDS="$BG_PIDS $!"
}

wait_bg() {
    [ -z "$BG_PIDS" ] && return 0
    # shellcheck disable=SC2086
    wait $BG_PIDS 2>/dev/null || true
    BG_PIDS=""
}

# ═════════════════════════════════════════════════════════════════
#  PHASE 1: Install Alpine build toolchain (slim — build-base only)
# ═════════════════════════════════════════════════════════════════
install_toolchain() {
    info "Installing Alpine GCC toolchain..."
    mkdir -p "$TOOLCHAIN"

    apkstatic="${SRCDIR}/apk-tools-static.apk"
    if [ ! -f "$apkstatic" ]; then
        tmphtml="${SRCDIR}/pkglist.html"
        wget -q -O "$tmphtml" "${ALPINE_MAIN}/" 2>/dev/null || die "Alpine mirror unreachable"
        apkname=$(grep -o 'apk-tools-static-[^"]*\.apk' "$tmphtml" | head -1)
        [ -z "$apkname" ] && die "No apk-tools-static found on mirror"
        fetch "${ALPINE_MAIN}/${apkname}" "$apkstatic"
    fi

    cd "$TOOLCHAIN"
    tar xf "$apkstatic" 2>/dev/null || gunzip -c "$apkstatic" | tar x 2>/dev/null
    apk_bin=$(find "$TOOLCHAIN" -name "apk.static" -type f | head -1)
    [ -z "$apk_bin" ] && apk_bin=$(find "$TOOLCHAIN" -name "apk" -type f | head -1)
    [ -z "$apk_bin" ] && die "apk binary not found after extraction"
    chmod +x "$apk_bin"

    alpine_root="${TOOLCHAIN}/alpine"
    mkdir -p "$alpine_root/etc/apk"
    echo "${ALPINE_MIRROR}/main" > "$alpine_root/etc/apk/repositories"

    # build-base already pulls in gcc, make, libc-dev, binutils, g++.
    # perl / linux-headers / standalone musl-dev were unused.
    info "Installing build-base..."
    "$apk_bin" --arch "$ALPINE_ARCH" --root "$alpine_root" --initdb \
        --no-progress --allow-untrusted \
        add alpine-baselayout build-base \
        2>&1 | tail -3

    [ ! -f "$alpine_root/usr/bin/gcc" ] && die "GCC install failed"
    info "Toolchain ready"
}

chroot_compile() {
    alpine_root="${TOOLCHAIN}/alpine"
    mount --bind /proc "$alpine_root/proc" 2>/dev/null
    mount --bind /sys "$alpine_root/sys" 2>/dev/null
    mount --bind /dev "$alpine_root/dev" 2>/dev/null
    mkdir -p "$alpine_root/src"
    mount --bind "$SRCDIR" "$alpine_root/src" 2>/dev/null
    chroot "$alpine_root" /bin/sh -c "$1"
    ret=$?
    umount "$alpine_root/src" 2>/dev/null
    umount "$alpine_root/dev" 2>/dev/null
    umount "$alpine_root/sys" 2>/dev/null
    umount "$alpine_root/proc" 2>/dev/null
    return $ret
}

# ═════════════════════════════════════════════════════════════════
#  PHASE 2: Dropbear SSH  (dropbear + dropbearkey only)
# ═════════════════════════════════════════════════════════════════
compile_dropbear() {
    info "=== Compiling Dropbear SSH ==="
    [ -d "$SRCDIR/dropbear-${DROPBEAR_VER}" ] || \
        tar -C "$SRCDIR" -xf "$SRCDIR/dropbear-${DROPBEAR_VER}.tar.bz2"

    chroot_compile "
        cd /src/dropbear-${DROPBEAR_VER}
        LDFLAGS='-static' CFLAGS='-Os -pipe' \
            ./configure --disable-zlib --disable-pam --enable-static >/dev/null
        echo 'Compiling Dropbear...'
        make PROGRAMS='dropbear dropbearkey' STATIC=1 -j${NCPU} 2>&1 | tail -3
    "

    db="$SRCDIR/dropbear-${DROPBEAR_VER}/dropbear"
    dk="$SRCDIR/dropbear-${DROPBEAR_VER}/dropbearkey"
    [ ! -f "$db" ] && die "Dropbear build produced no binary"
    mkdir -p "$BUILDROOT/usr/sbin"
    cp "$db" "$BUILDROOT/usr/sbin/dropbear"
    cp "$dk" "$BUILDROOT/usr/bin/dropbearkey"
    chmod 755 "$BUILDROOT/usr/sbin/dropbear" "$BUILDROOT/usr/bin/dropbearkey"
    info "Dropbear compiled"
}

start_ssh() {
    info "Generating SSH host keys..."
    mkdir -p /etc/dropbear "$BUILDROOT/etc/dropbear"
    keygen="$BUILDROOT/usr/bin/dropbearkey"
    [ -x "$keygen" ] || { warn "dropbearkey missing"; return 1; }

    "$keygen" -t ed25519 -f "$BUILDROOT/etc/dropbear/dropbear_ed25519_host_key" 2>/dev/null
    "$keygen" -t rsa -s 2048 -f "$BUILDROOT/etc/dropbear/dropbear_rsa_host_key" 2>/dev/null
    cp "$BUILDROOT/etc/dropbear/"* /etc/dropbear/ 2>/dev/null

    cp /etc/passwd "$BUILDROOT/etc/passwd" 2>/dev/null
    cp /etc/group "$BUILDROOT/etc/group" 2>/dev/null
    cp /etc/resolv.conf "$BUILDROOT/etc/resolv.conf" 2>/dev/null
    printf 'root::0:0:99999:7:::\n' > "$BUILDROOT/etc/shadow"
    chmod 640 "$BUILDROOT/etc/shadow"
    printf '/bin/sh\n' > "$BUILDROOT/etc/shells"

    "$BUILDROOT/usr/sbin/dropbear" \
        -r "$BUILDROOT/etc/dropbear/dropbear_ed25519_host_key" \
        -r "$BUILDROOT/etc/dropbear/dropbear_rsa_host_key" \
        -p 22 -R 2>/dev/null && info "SSH running on port 22"
}

# ═════════════════════════════════════════════════════════════════
#  PHASE 3: Links browser
# ═════════════════════════════════════════════════════════════════
compile_links() {
    info "=== Compiling Links browser ==="
    [ -d "$SRCDIR/links-${LINKS_VER}" ] || \
        tar -C "$SRCDIR" -xf "$SRCDIR/links-${LINKS_VER}.tar.gz"

    chroot_compile "
        cd /src/links-${LINKS_VER}
        LDFLAGS='-static' CFLAGS='-Os -pipe' \
            ./configure --without-x --without-fb --without-directfb \
                        --without-pmshell --without-atheos \
                        --without-openssl --without-nss >/dev/null
        echo 'Compiling Links...'
        make -j${NCPU} 2>&1 | tail -3
    "

    lnk="$SRCDIR/links-${LINKS_VER}/links"
    if [ -f "$lnk" ]; then
        cp "$lnk" "$BUILDROOT/usr/bin/links"
        chmod 755 "$BUILDROOT/usr/bin/links"
        info "Links browser installed"
    else
        warn "Links build failed (non-fatal)"
    fi
}

finalize() {
    info "Cleaning up..."
    if [ -d "$TOOLCHAIN" ]; then
        tc_mb=$(du -sm "$TOOLCHAIN" 2>/dev/null | cut -f1)
        info "Freeing ${tc_mb:-?}MB (toolchain)"
        rm -rf "$TOOLCHAIN"
    fi
    if [ -d "$SRCDIR" ]; then
        src_mb=$(du -sm "$SRCDIR" 2>/dev/null | cut -f1)
        info "Freeing ${src_mb:-?}MB (sources)"
        rm -rf "$SRCDIR"
    fi
}

# ═════════════════════════════════════════════════════════════════
#  Main pipeline
# ═════════════════════════════════════════════════════════════════
notify "Downloading static BusyBox + toolchain..." "BUILD STARTING" "33"

phase0_ramdisk_and_full_busybox

# Kick off source downloads in the background; they'll overlap with
# the much larger apk toolchain download.
fetch_bg "$DROPBEAR_URL" "$SRCDIR/dropbear-${DROPBEAR_VER}.tar.bz2"
fetch_bg "$LINKS_URL"    "$SRCDIR/links-${LINKS_VER}.tar.gz"

install_toolchain

# Make sure the background tarball downloads are done before we compile.
wait_bg

compile_dropbear
start_ssh

IP=$(ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | grep -v '^127\.' | head -1 2>/dev/null)
notify "SSH: ssh root@${IP:-<ip>} (no password)   " "50% — SSH READY" "32"

compile_links

finalize

NCMDS=$(ls "$BUILDROOT/bin/" "$BUILDROOT/sbin/" "$BUILDROOT/usr/bin/" "$BUILDROOT/usr/sbin/" 2>/dev/null | sort -u | wc -l)
notify "${NCMDS} commands, SSH, browser ready      " "100% — COMPLETE" "32"

exit 0
