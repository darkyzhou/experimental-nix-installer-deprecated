#!/bin/sh
# shellcheck shell=dash

# nix4loong installer script - specialized for LoongArch platform
# This script is adapted for the nix4loong project, which provides NixOS for LoongArch64 processors.
#
# If you need an offline install, or you'd prefer to run the binary directly, head to
# https://github.com/NixOS/experimental-nix-installer/releases then pick the version and platform
# most appropriate for your deployment target.
#
# This script only supports LoongArch64 Linux systems with LA64v1.0 architecture standard (LSX + FPU).
# It runs on Unix shells like {a,ba,da,k,z}sh. It uses the common `local`
# extension. Note: Most shells limit `local` to 1 var per line, contra bash.

# This script is based off https://github.com/rust-lang/rustup/blob/f8d7b3baba7a63237cb2b82ef49a68a37dd0633c/rustup-init.sh

if [ "$KSH_VERSION" = 'Version JM 93t+ 2010-03-05' ]; then
    # The version of ksh93 that ships with many illumos systems does not
    # support the "local" extension.  Print a message rather than fail in
    # subtle ways later on:
    echo 'nix4loong-installer does not work with this ksh93 version; please try bash!' >&2
    exit 1
fi

set -u

# If NIX_INSTALLER_FORCE_ALLOW_HTTP is unset or empty, default it.
NIX_INSTALLER_BINARY_ROOT="${NIX_INSTALLER_BINARY_ROOT:-https://download.nix4loong.cn/nix-installer/$assemble_installer_templated_version}"

main() {
    downloader --check
    need_cmd uname
    need_cmd mktemp
    need_cmd chmod
    need_cmd mkdir
    need_cmd rm
    need_cmd rmdir

    get_architecture || return 1
    local _arch="$RETVAL"
    assert_nz "$_arch" "arch"

    local _url="${NIX_INSTALLER_OVERRIDE_URL-${NIX_INSTALLER_BINARY_ROOT}/nix-installer-${_arch}}"

    local _dir
    if ! _dir="$(ensure mktemp -d)"; then
        # Because the previous command ran in a subshell, we must manually
        # propagate exit status.
        exit 1
    fi
    local _file="${_dir}/nix-installer"

    local _ansi_escapes_are_valid=false
    if [ -t 2 ]; then
        if [ "${TERM+set}" = 'set' ]; then
            case "$TERM" in
                xterm*|rxvt*|urxvt*|linux*|vt*)
                    _ansi_escapes_are_valid=true
                ;;
            esac
        fi
    fi

    # check if we have to use /dev/tty to prompt the user
    local need_tty=yes
    for arg in "$@"; do
        case "$arg" in
            --no-confirm)
                need_tty=no
                ;;
            *)
                continue
                ;;
        esac
    done
    if [ "${NIX_INSTALLER_NO_CONFIRM-}" ]; then
        need_tty=no
    fi

    if $_ansi_escapes_are_valid; then
        printf "\33[1minfo:\33[0m downloading nix4loong installer \33[4m%s\33[0m\n" "$_url" 1>&2
    else
        printf 'info: downloading nix4loong installer (%s)\n' "$_url" 1>&2
    fi

    ensure mkdir -p "$_dir"
    ensure downloader "$_url" "$_file" "$_arch"
    ensure chmod u+x "$_file"
    if [ ! -x "$_file" ]; then
        printf '%s\n' "Cannot execute $_file (likely because of mounting /tmp as noexec)." 1>&2
        printf '%s\n' "Please copy the file to a location where you can execute binaries and run ./nix-installer." 1>&2
        exit 1
    fi

    if [ "$need_tty" = "yes" ] && [ ! -t 0 ]; then
        # The installer is going to want to ask for confirmation by
        # reading stdin.  This script was piped into `sh` though and
        # doesn't have stdin to pass to its children. Instead we're going
        # to explicitly connect /dev/tty to the installer's stdin.
        if [ ! -t 1 ]; then
            err "Unable to run interactively. Run with --no-confirm to accept defaults, --help for additional options"
        fi

        ignore "$_file" "$@" < /dev/tty
    else
        ignore "$_file" "$@"
    fi

    local _retval=$?

    ignore rm "$_file"
    ignore rmdir "$_dir"

    return "$_retval"
}

check_proc() {
    # Check for /proc by looking for the /proc/self/exe link
    # This is only run on Linux
    if ! test -L /proc/self/exe ; then
        err "fatal: Unable to find /proc/self/exe.  Is /proc mounted?  Installation cannot proceed without /proc."
    fi
}

# Detect the Linux/LoongArch UAPI flavor, with all errors being non-fatal.
# Returns 0 or 234 in case of successful detection, 1 otherwise (/tmp being
# noexec, or other causes).
check_loongarch_uapi() {
    need_cmd base64

    local _tmp
    if ! _tmp="$(ensure mktemp)"; then
        return 1
    fi

    # Minimal Linux/LoongArch UAPI detection, exiting with 0 in case of
    # upstream ("new world") UAPI, and 234 (-EINVAL truncated) in case of
    # old-world (as deployed on several early commercial Linux distributions
    # for LoongArch).
    #
    # See https://gist.github.com/xen0n/5ee04aaa6cecc5c7794b9a0c3b65fc7f for
    # source to this helper binary.
    ignore base64 -d > "$_tmp" <<EOF
f0VMRgIBAQAAAAAAAAAAAAIAAgEBAAAAeAAgAAAAAABAAAAAAAAAAAAAAAAAAAAAQQAAAEAAOAAB
AAAAAAAAAAEAAAAFAAAAAAAAAAAAAAAAACAAAAAAAAAAIAAAAAAAJAAAAAAAAAAkAAAAAAAAAAAA
AQAAAAAABCiAAwUAFQAGABUAByCAAwsYggMAACsAC3iBAwAAKwAxen0n
EOF

    ignore chmod u+x "$_tmp"
    if [ ! -x "$_tmp" ]; then
        ignore rm "$_tmp"
        return 1
    fi

    "$_tmp"
    local _retval=$?

    ignore rm "$_tmp"
    return "$_retval"
}

ensure_loongarch_uapi() {
    check_loongarch_uapi
    case $? in
        0)
            return 0
            ;;
        234)
            err "Your Linux kernel does not provide the ABI required by this Nix distribution." \
                "Please check with your OS provider for how to obtain a compatible Nix package for your system."
            ;;
        *)
            warn "Cannot determine current system's ABI flavor, continuing anyway." \
                 "Note that Nix4Loong only works with the upstream kernel ABI." \
                 "Installation will fail if your running kernel happens to be incompatible."
            ;;
    esac
}

ensure_la64v1_0_support() {
    # Check if the LoongArch processor supports LA64v1.0 architecture standard
    # This includes LSX (LoongArch SIMD eXtension) and FPU support
    if [ ! -r /proc/cpuinfo ]; then
        err "fatal: Unable to read /proc/cpuinfo. Cannot verify LA64v1.0 architecture support."
    fi
    
    # Check for LSX support in Features column
    if ! grep -i "^Features" /proc/cpuinfo | grep -qi "lsx"; then
        err "fatal: This LoongArch processor does not support LSX instruction set. nix4loong requires LA64v1.0 architecture standard with LSX support."
    fi
    
    # Check for FPU support in Features column
    if ! grep -i "^Features" /proc/cpuinfo | grep -qi "fpu"; then
        err "fatal: This LoongArch processor does not support FPU (Floating Point Unit). nix4loong requires LA64v1.0 architecture standard with FPU support."
    fi
}

get_architecture() {
    local _ostype _cputype _arch
    _ostype="$(uname -s)"
    _cputype="$(uname -m)"

    # nix4loong only supports Linux
    if [ "$_ostype" != "Linux" ]; then
        err "fatal: nix4loong only supports Linux. Detected OS: $_ostype"
    fi

    # Check for Android (not supported)
    if [ "$(uname -o)" = "Android" ]; then
        err "fatal: nix4loong does not support Android"
    fi

    # Verify /proc is available
    check_proc
    
    # nix4loong only supports LoongArch64
    case "$_cputype" in
        loongarch64)
            _cputype=loongarch64
            ;;
        *)
            err "fatal: nix4loong only supports LoongArch64. Detected CPU type: $_cputype"
            ;;
    esac

    # Ensure ABI compatibility
    ensure_loongarch_uapi
    
    # Ensure LA64v1.0 architecture support (LSX + FPU)
    ensure_la64v1_0_support

    _arch="${_cputype}-linux"
    RETVAL="$_arch"
}

say() {
    printf 'nix4loong-installer: %s\n' "$1"
}

err() {
    say "$1" >&2
    exit 1
}

need_cmd() {
    if ! check_cmd "$1"; then
        err "need '$1' (command not found)"
    fi
}

check_cmd() {
    command -v "$1" > /dev/null 2>&1
}

assert_nz() {
    if [ -z "$1" ]; then err "assert_nz $2"; fi
}

# Run a command that should never fail. If the command fails execution
# will immediately terminate with an error showing the failing
# command.
ensure() {
    if ! "$@"; then err "command failed: $*"; fi
}

# This is just for indicating that commands' results are being
# intentionally ignored. Usually, because it's being executed
# as part of error handling.
ignore() {
    "$@"
}

# This wraps curl or wget. Try curl first, if not installed,
# use wget instead.
downloader() {
    local _dld
    local _ciphersuites
    local _err
    local _status
    local _retry
    if check_cmd curl; then
        _dld=curl
    elif check_cmd wget; then
        _dld=wget
    else
        _dld='curl or wget' # to be used in error message of need_cmd
    fi

    if [ "$1" = --check ]; then
        need_cmd "$_dld"
    elif [ "$_dld" = curl ]; then
        check_curl_for_retry_support
        _retry="$RETVAL"
        get_ciphersuites_for_curl
        _ciphersuites="$RETVAL"
        if [ -n "$_ciphersuites" ]; then
            if [ -n "${NIX_INSTALLER_FORCE_ALLOW_HTTP-}" ]; then
                # shellcheck disable=SC2086 # ignore because $_retry could be a flag (e.g. `--retry 5`)
                _err=$(curl $_retry --silent --show-error --fail --location "$1" --output "$2" 2>&1)
            else
                # shellcheck disable=SC2086 # ignore because $_retry could be a flag (e.g. `--retry 5`)
                _err=$(curl $_retry --proto '=https' --tlsv1.2 --ciphers "$_ciphersuites" --silent --show-error --fail --location "$1" --output "$2" 2>&1)
            fi
            _status=$?
        else
            echo "Warning: Not enforcing strong cipher suites for TLS, this is potentially less secure"
            if ! check_help_for "$3" curl --proto --tlsv1.2; then
                echo "Warning: Not enforcing TLS v1.2, this is potentially less secure"
                # shellcheck disable=SC2086 # ignore because $_retry could be a flag (e.g. `--retry 5`)
                _err=$(curl $_retry --silent --show-error --fail --location "$1" --output "$2" 2>&1)
                _status=$?
            else
                # shellcheck disable=SC2086 # ignore because $_retry could be a flag (e.g. `--retry 5`)
                _err=$(curl $_retry --proto '=https' --tlsv1.2 --silent --show-error --fail --location "$1" --output "$2" 2>&1)
                _status=$?
            fi
        fi
        if [ -n "$_err" ]; then
            echo "$_err" >&2
            if echo "$_err" | grep -q 404$; then
                err "nix4loong installer for platform '$3' not found, this may be unsupported"
            fi
        fi
        return $_status
    elif [ "$_dld" = wget ]; then
        if [ "$(wget -V 2>&1|head -2|tail -1|cut -f1 -d" ")" = "BusyBox" ]; then
            echo "Warning: using the BusyBox version of wget.  Not enforcing strong cipher suites for TLS or TLS v1.2, this is potentially less secure"
            _err=$(wget "$1" -O "$2" 2>&1)
            _status=$?
        else
            get_ciphersuites_for_wget
            _ciphersuites="$RETVAL"
            if [ -n "$_ciphersuites" ]; then
                _err=$(wget --https-only --secure-protocol=TLSv1_2 --ciphers "$_ciphersuites" "$1" -O "$2" 2>&1)
                _status=$?
            else
                echo "Warning: Not enforcing strong cipher suites for TLS, this is potentially less secure"
                if ! check_help_for "$3" wget --https-only --secure-protocol; then
                    echo "Warning: Not enforcing TLS v1.2, this is potentially less secure"
                    _err=$(wget "$1" -O "$2" 2>&1)
                    _status=$?
                else
                    _err=$(wget --https-only --secure-protocol=TLSv1_2 "$1" -O "$2" 2>&1)
                    _status=$?
                fi
            fi
        fi
        if [ -n "$_err" ]; then
            echo "$_err" >&2
            if echo "$_err" | grep -q ' 404 Not Found$'; then
                err "nix4loong installer for platform '$3' not found, this may be unsupported"
            fi
        fi
        return $_status
    else
        err "Unknown downloader"   # should not reach here
    fi
}

check_help_for() {
    local _arch
    local _cmd
    local _arg
    _arch="$1"
    shift
    _cmd="$1"
    shift

    local _category
    if "$_cmd" --help | grep -q 'For all options use the manual or "--help all".'; then
      _category="all"
    else
      _category=""
    fi

    case "$_arch" in

        *darwin*)
        if check_cmd sw_vers; then
            case $(sw_vers -productVersion) in
                10.*)
                    # If we're running on macOS, older than 10.13, then we always
                    # fail to find these options to force fallback
                    if [ "$(sw_vers -productVersion | cut -d. -f2)" -lt 13 ]; then
                        # Older than 10.13
                        echo "Warning: Detected macOS platform older than 10.13"
                        return 1
                    fi
                    ;;
                11.*)
                    # We assume Big Sur will be OK for now
                    ;;
                *)
                    # Unknown product version, warn and continue
                    echo "Warning: Detected unknown macOS major version: $(sw_vers -productVersion)"
                    echo "Warning TLS capabilities detection may fail"
                    ;;
            esac
        fi
        ;;

    esac

    for _arg in "$@"; do
        if ! "$_cmd" --help $_category | grep -q -- "$_arg"; then
            return 1
        fi
    done

    true # not strictly needed
}

# Check if curl supports the --retry flag, then pass it to the curl invocation.
check_curl_for_retry_support() {
  local _retry_supported=""
  # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
  if check_help_for "notspecified" "curl" "--retry"; then
    _retry_supported="--retry 3"
  fi

  RETVAL="$_retry_supported"
}

# Return cipher suite string specified by user, otherwise return strong TLS 1.2-1.3 cipher suites
# if support by local tools is detected. Detection currently supports these curl backends:
# GnuTLS and OpenSSL (possibly also LibreSSL and BoringSSL). Return value can be empty.
get_ciphersuites_for_curl() {
    if [ -n "${RUSTUP_TLS_CIPHERSUITES-}" ]; then
        # user specified custom cipher suites, assume they know what they're doing
        RETVAL="$RUSTUP_TLS_CIPHERSUITES"
        return
    fi

    local _openssl_syntax="no"
    local _gnutls_syntax="no"
    local _backend_supported="yes"
    if curl -V | grep -q ' OpenSSL/'; then
        _openssl_syntax="yes"
    elif curl -V | grep -iq ' LibreSSL/'; then
        _openssl_syntax="yes"
    elif curl -V | grep -iq ' BoringSSL/'; then
        _openssl_syntax="yes"
    elif curl -V | grep -iq ' GnuTLS/'; then
        _gnutls_syntax="yes"
    else
        _backend_supported="no"
    fi

    local _args_supported="no"
    if [ "$_backend_supported" = "yes" ]; then
        # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
        if check_help_for "notspecified" "curl" "--tlsv1.2" "--ciphers" "--proto"; then
            _args_supported="yes"
        fi
    fi

    local _cs=""
    if [ "$_args_supported" = "yes" ]; then
        if [ "$_openssl_syntax" = "yes" ]; then
            _cs=$(get_strong_ciphersuites_for "openssl")
        elif [ "$_gnutls_syntax" = "yes" ]; then
            _cs=$(get_strong_ciphersuites_for "gnutls")
        fi
    fi

    RETVAL="$_cs"
}

# Return cipher suite string specified by user, otherwise return strong TLS 1.2-1.3 cipher suites
# if support by local tools is detected. Detection currently supports these wget backends:
# GnuTLS and OpenSSL (possibly also LibreSSL and BoringSSL). Return value can be empty.
get_ciphersuites_for_wget() {
    if [ -n "${RUSTUP_TLS_CIPHERSUITES-}" ]; then
        # user specified custom cipher suites, assume they know what they're doing
        RETVAL="$RUSTUP_TLS_CIPHERSUITES"
        return
    fi

    local _cs=""
    if wget -V | grep -q '\-DHAVE_LIBSSL'; then
        # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
        if check_help_for "notspecified" "wget" "TLSv1_2" "--ciphers" "--https-only" "--secure-protocol"; then
            _cs=$(get_strong_ciphersuites_for "openssl")
        fi
    elif wget -V | grep -q '\-DHAVE_LIBGNUTLS'; then
        # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
        if check_help_for "notspecified" "wget" "TLSv1_2" "--ciphers" "--https-only" "--secure-protocol"; then
            _cs=$(get_strong_ciphersuites_for "gnutls")
        fi
    fi

    RETVAL="$_cs"
}

# Return strong TLS 1.2-1.3 cipher suites in OpenSSL or GnuTLS syntax. TLS 1.2
# excludes non-ECDHE and non-AEAD cipher suites. DHE is excluded due to bad
# DH params often found on servers (see RFC 7919). Sequence matches or is
# similar to Firefox 68 ESR with weak cipher suites disabled via about:config.
# $1 must be openssl or gnutls.
get_strong_ciphersuites_for() {
    if [ "$1" = "openssl" ]; then
        # OpenSSL is forgiving of unknown values, no problems with TLS 1.3 values on versions that don't support it yet.
        echo "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
    elif [ "$1" = "gnutls" ]; then
        # GnuTLS isn't forgiving of unknown values, so this may require a GnuTLS version that supports TLS 1.3 even if wget doesn't.
        # Begin with SECURE128 (and higher) then remove/add to build cipher suites. Produces same 9 cipher suites as OpenSSL but in slightly different order.
        echo "SECURE128:-VERS-SSL3.0:-VERS-TLS1.0:-VERS-TLS1.1:-VERS-DTLS-ALL:-CIPHER-ALL:-MAC-ALL:-KX-ALL:+AEAD:+ECDHE-ECDSA:+ECDHE-RSA:+AES-128-GCM:+CHACHA20-POLY1305:+AES-256-GCM"
    fi
}

main "$@" || exit 1
