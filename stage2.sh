#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
#  Sarban Linux — Stage 2 Bootstrap
#
#  Downloaded by the floppy after network comes up.
#  Compiles Dropbear SSH first, starts sshd (50%), then compiles
#  full BusyBox + Links browser (100%). Entire build lives in
#  a tmpfs ramdisk.
#
#  Notifications appear on the user's console at each milestone.
# ═══════════════════════════════════════════════════════════════════
set -e

RAMDISK="/ramdisk"
SRCDIR="/ramdisk/src"
BUILDROOT="/ramdisk/root"
TOOLCHAIN="/ramdisk/toolchain"
NCPU=$(nproc 2>/dev/null || echo 1)

ALPINE_VER="3.20"
ALPINE_ARCH="x86_64"
ALPINE_MIRROR="http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}"
ALPINE_MAIN="${ALPINE_MIRROR}/main/${ALPINE_ARCH}"

BUSYBOX_VER="1.36.1"
BUSYBOX_URL="http://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2"
DROPBEAR_VER="2024.86"
DROPBEAR_URL="https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VER}.tar.bz2"
LINKS_VER="2.30"
LINKS_URL="http://links.twibright.com/download/links-${LINKS_VER}.tar.gz"

# ── Console notification ─────────────────────────────────────────
notify() {
    msg="$1"
    title="$2"
    color="${3:-36}"
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

fetch() {
    url="$1"
    dest="$2"
    if [ -f "$dest" ]; then
        return 0
    fi
    info "Fetching $(basename "$dest")..."
    if ! wget -q -O "$dest" "$url" 2>/dev/null; then
        # Retry with HTTP if HTTPS fails
        http_url=$(echo "$url" | sed 's|^https://|http://|')
        if [ "$http_url" != "$url" ]; then
            wget -q -O "$dest" "$http_url" 2>/dev/null || :
        fi
    fi
    if [ ! -f "$dest" ] || [ "$(stat -c%s "$dest" 2>/dev/null)" -lt 1000 ]; then
        rm -f "$dest"
        die "Download failed: $url"
    fi
}

# ── Make all the directories we need. EXPLICITLY (no brace expansion). ──
#   ash doesn't expand {a,b,c} so we must write every path out.
setup_ramdisk() {
    info "Creating ramdisk (80% of RAM)..."
    total_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    ramdisk_kb=$(( total_kb * 80 / 100 ))
    mkdir -p "$RAMDISK"
    if ! mountpoint -q "$RAMDISK" 2>/dev/null; then
        mount -t tmpfs -o size=${ramdisk_kb}k tmpfs "$RAMDISK"
    fi

    mkdir -p "$SRCDIR"
    mkdir -p "$BUILDROOT"
    mkdir -p "$BUILDROOT/bin"
    mkdir -p "$BUILDROOT/sbin"
    mkdir -p "$BUILDROOT/usr"
    mkdir -p "$BUILDROOT/usr/bin"
    mkdir -p "$BUILDROOT/usr/sbin"
    mkdir -p "$BUILDROOT/etc"
    mkdir -p "$BUILDROOT/etc/dropbear"
    mkdir -p "$BUILDROOT/root"
    mkdir -p "$BUILDROOT/tmp"
    mkdir -p "$BUILDROOT/var"
    mkdir -p "$BUILDROOT/var/log"
    mkdir -p "$BUILDROOT/var/run"
    mkdir -p "$BUILDROOT/dev"
    mkdir -p "$BUILDROOT/proc"
    mkdir -p "$BUILDROOT/sys"
    mkdir -p "$BUILDROOT/run"
    mkdir -p "$BUILDROOT/usr/share"
    mkdir -p "$BUILDROOT/usr/share/udhcpc"
}

install_toolchain() {
    info "Installing Alpine Linux build toolchain..."
    mkdir -p "$TOOLCHAIN"

    apkstatic="${SRCDIR}/apk-tools-static.apk"
    if [ ! -f "$apkstatic" ]; then
        tmphtml="${SRCDIR}/pkglist.html"
        wget -q -O "$tmphtml" "${ALPINE_MAIN}/" 2>/dev/null || die "Cannot reach Alpine mirror"
        apkname=$(grep -o 'apk-tools-static-[^"]*\.apk' "$tmphtml" 2>/dev/null | head -1)
        if [ -z "$apkname" ]; then
            die "Cannot find apk-tools-static on Alpine mirror"
        fi
        fetch "${ALPINE_MAIN}/${apkname}" "$apkstatic"
    fi

    cd "$TOOLCHAIN"
    tar xf "$apkstatic" 2>/dev/null || gunzip -c "$apkstatic" | tar x 2>/dev/null

    apk_bin=$(find "$TOOLCHAIN" -name "apk.static" -type f 2>/dev/null | head -1)
    if [ -z "$apk_bin" ]; then
        apk_bin=$(find "$TOOLCHAIN" -name "apk" -type f 2>/dev/null | head -1)
    fi
    if [ -z "$apk_bin" ]; then
        die "apk binary not found after extraction"
    fi
    chmod +x "$apk_bin"

    alpine_root="${TOOLCHAIN}/alpine"
    mkdir -p "$alpine_root/etc/apk"
    echo "${ALPINE_MIRROR}/main" > "$alpine_root/etc/apk/repositories"

    info "Installing GCC + build tools..."
    "$apk_bin" --arch "$ALPINE_ARCH" --root "$alpine_root" --initdb \
        --no-progress --allow-untrusted \
        add alpine-baselayout busybox build-base gcc make musl-dev linux-headers perl \
        2>&1 | tail -3

    if [ ! -f "$alpine_root/usr/bin/gcc" ]; then
        die "GCC install failed"
    fi
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
#  PHASE 1: Dropbear SSH
# ═════════════════════════════════════════════════════════════════
compile_dropbear() {
    info "=== PHASE 1: Dropbear SSH ==="
    cd "$SRCDIR"
    fetch "$DROPBEAR_URL" "$SRCDIR/dropbear-${DROPBEAR_VER}.tar.bz2"
    if [ ! -d "dropbear-${DROPBEAR_VER}" ]; then
        tar xf "dropbear-${DROPBEAR_VER}.tar.bz2"
    fi

    chroot_compile "
        cd /src/dropbear-${DROPBEAR_VER}
        make clean 2>/dev/null || true
        LDFLAGS='-static' CFLAGS='-Os -s' ./configure --disable-zlib --disable-pam --enable-static 2>/dev/null
        echo 'Compiling Dropbear...'
        make PROGRAMS='dropbear dbclient dropbearkey scp' STATIC=1 MULTI=1 SCPPROGRESS=1 -j${NCPU} 2>&1 | tail -3
    "

    multi="$SRCDIR/dropbear-${DROPBEAR_VER}/dropbearmulti"
    if [ ! -f "$multi" ]; then
        die "Dropbear build produced no binary"
    fi
    cp "$multi" "$BUILDROOT/usr/bin/dropbearmulti"
    chmod 755 "$BUILDROOT/usr/bin/dropbearmulti"
    for prog in dropbear dbclient dropbearkey scp ssh; do
        ln -sf dropbearmulti "$BUILDROOT/usr/bin/$prog"
    done
    info "Dropbear compiled"
}

start_ssh() {
    info "Generating SSH host keys..."
    mkdir -p /etc/dropbear
    mkdir -p "$BUILDROOT/etc/dropbear"
    keygen="$BUILDROOT/usr/bin/dropbearkey"
    if [ ! -x "$keygen" ]; then
        warn "dropbearkey missing"
        return 1
    fi

    "$keygen" -t ed25519 -f "$BUILDROOT/etc/dropbear/dropbear_ed25519_host_key" 2>/dev/null
    "$keygen" -t rsa -s 2048 -f "$BUILDROOT/etc/dropbear/dropbear_rsa_host_key" 2>/dev/null
    cp "$BUILDROOT/etc/dropbear/"* /etc/dropbear/ 2>/dev/null

    cp /etc/passwd "$BUILDROOT/etc/passwd" 2>/dev/null
    cp /etc/group "$BUILDROOT/etc/group" 2>/dev/null
    cp /etc/resolv.conf "$BUILDROOT/etc/resolv.conf" 2>/dev/null
    echo "root::0:0:99999:7:::" > "$BUILDROOT/etc/shadow"
    chmod 640 "$BUILDROOT/etc/shadow"
    echo "/bin/sh" > "$BUILDROOT/etc/shells"

    "$BUILDROOT/usr/bin/dropbear" \
        -r "$BUILDROOT/etc/dropbear/dropbear_ed25519_host_key" \
        -r "$BUILDROOT/etc/dropbear/dropbear_rsa_host_key" \
        -p 22 -R 2>/dev/null && info "SSH running on port 22"
}

# ═════════════════════════════════════════════════════════════════
#  PHASE 2: Full BusyBox
# ═════════════════════════════════════════════════════════════════
compile_busybox() {
    info "=== PHASE 2: BusyBox (full config) ==="
    cd "$SRCDIR"
    fetch "$BUSYBOX_URL" "$SRCDIR/busybox-${BUSYBOX_VER}.tar.bz2"
    if [ ! -d "busybox-${BUSYBOX_VER}" ]; then
        tar xf "busybox-${BUSYBOX_VER}.tar.bz2"
    fi

    chroot_compile "
        cd /src/busybox-${BUSYBOX_VER}
        make clean 2>/dev/null || true
        make defconfig
        sed -i 's|^# CONFIG_STATIC is not set|CONFIG_STATIC=y|' .config
        sed -i 's|^CONFIG_TC=y|# CONFIG_TC is not set|' .config
        sed -i 's|^CONFIG_FEATURE_TC_INGRESS=y|# CONFIG_FEATURE_TC_INGRESS is not set|' .config
        sed -i 's|^CONFIG_SSL_CLIENT=y|# CONFIG_SSL_CLIENT is not set|' .config
        yes '' | make oldconfig > /dev/null 2>&1 || true
        echo 'Compiling BusyBox...'
        make -j${NCPU} 2>&1 | tail -3
    "

    bb="$SRCDIR/busybox-${BUSYBOX_VER}/busybox"
    if [ ! -f "$bb" ]; then
        die "BusyBox build failed"
    fi
    cp "$bb" "$BUILDROOT/bin/busybox"
    chmod 755 "$BUILDROOT/bin/busybox"
    "$BUILDROOT/bin/busybox" --install -s "$BUILDROOT/bin" 2>/dev/null
    "$BUILDROOT/bin/busybox" --install -s "$BUILDROOT/sbin" 2>/dev/null
    "$BUILDROOT/bin/busybox" --install -s "$BUILDROOT/usr/bin" 2>/dev/null
    "$BUILDROOT/bin/busybox" --install -s "$BUILDROOT/usr/sbin" 2>/dev/null
    info "BusyBox installed"
}

# ═════════════════════════════════════════════════════════════════
#  PHASE 3: Links browser
# ═════════════════════════════════════════════════════════════════
compile_links() {
    info "=== PHASE 3: Links text browser ==="
    cd "$SRCDIR"
    fetch "$LINKS_URL" "$SRCDIR/links-${LINKS_VER}.tar.gz"
    if [ ! -d "links-${LINKS_VER}" ]; then
        tar xf "links-${LINKS_VER}.tar.gz"
    fi

    chroot_compile "
        cd /src/links-${LINKS_VER}
        make clean 2>/dev/null || true
        LDFLAGS='-static' CFLAGS='-Os -s' ./configure --without-x --without-fb --without-directfb --without-pmshell --without-atheos --without-openssl --without-nss 2>/dev/null
        echo 'Compiling Links...'
        make -j${NCPU} 2>&1 | tail -3
    "

    lnk="$SRCDIR/links-${LINKS_VER}/links"
    if [ -f "$lnk" ]; then
        cp "$lnk" "$BUILDROOT/usr/bin/links"
        chmod 755 "$BUILDROOT/usr/bin/links"
    fi
}

finalize() {
    info "Cleaning up..."
    if [ -d "$TOOLCHAIN" ]; then
        tc_mb=$(du -sm "$TOOLCHAIN" | cut -f1)
        info "Freeing ${tc_mb}MB (toolchain)"
        rm -rf "$TOOLCHAIN"
    fi
    if [ -d "$SRCDIR" ]; then
        src_mb=$(du -sm "$SRCDIR" | cut -f1)
        info "Freeing ${src_mb}MB (sources)"
        rm -rf "$SRCDIR"
    fi
    export PATH="$BUILDROOT/bin:$BUILDROOT/sbin:$BUILDROOT/usr/bin:$BUILDROOT/usr/sbin:$PATH"
}

# ═════════════════════════════════════════════════════════════════
#  Main pipeline
# ═════════════════════════════════════════════════════════════════
notify "Downloading toolchain and source code..." "BUILD STARTING" "33"

setup_ramdisk
install_toolchain

# Phase 1: SSH
compile_dropbear
start_ssh

IP=$(ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | grep -v '^127\.' | head -1)
notify "SSH: ssh root@${IP:-<ip>} (no password)   " "50% — SSH READY" "32"

# Phase 2: BusyBox full
compile_busybox

# Phase 3: Links
compile_links

finalize

NCMDS=$(ls "$BUILDROOT/bin/" "$BUILDROOT/sbin/" "$BUILDROOT/usr/bin/" "$BUILDROOT/usr/sbin/" 2>/dev/null | sort -u | wc -l)
notify "${NCMDS} commands, SSH, browser ready      " "100% — COMPLETE" "32"

exit 0
