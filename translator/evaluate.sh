#!/usr/bin/env bash
# translator/evaluate.sh: the two-pass Void template evaluator.
#
# Sources a srcpkgs-style template in an isolated, stubbed xbps-src
# environment and writes the fixed dump directory the Python side
# (chytrans/emit) consumes.
#
# Started life as a quick feasibility spike, then hardened:
#   * two passes with xbps-src semantics: pass 1 in a discarded subshell
#     harvests build_options/build_options_default; pass 2 re-sources in a
#     FRESH subshell with build_option_<x>=1 per default (never re-source in
#     one shell: string += assignments would double-append);
#   * while a template is being sourced, PATH points at an empty directory
#     (readonly, so the template can't repoint it): only the stub functions
#     and bash builtins resolve, and every real binary a template names is
#     an unexpected command;
#   * command_not_found_handle makes any unexpected command at source time a
#     hard failure, named on stderr;
#   * no process substitution anywhere (/dev/fd may be absent; the spike hit
#     this); temp files and pure-bash set diffs instead.
#
# Boundary note: everything above is hardening against accidental or
# sloppy templates, NOT a security boundary -- this script `source`s
# untrusted bash with bash itself as the interpreter, and a determined
# template can escape any in-process stub scheme. The actual trust
# boundary is the disposable container: evaluation only ever runs
# inside a throwaway CI container (see .github/workflows/repo-sync.yml,
# build gate), never against a host worth keeping. Keep it that way.
#
# Usage: bash translator/evaluate.sh <srcpkg-dir> <dump-out-dir>
#
#   <srcpkg-dir>     contains `template` (+ patches/, files/, not read here)
#   <dump-out-dir>   parent directory; on success <dump-out-dir>/<pkgname>/
#                    is (re)created with:
#                      vars        one "key<TAB>value" per line, value escapes
# \t \n \\; all 20 keys always present
#                      options     resolved build options, "name=0|1" per line
#                      functions/ one file per defined do_*/pre_*/post_*/
#                                  *_package function, body verbatim
#
#   Exit 0 on success (dump written, nothing on stdout);
#   nonzero + a one-line stderr reason on any evaluation failure.
#
# Function body extraction, pinned for determinism: the body is the output of
# `declare -f <name>` (bash's canonical re-formatting: 4-space indent, `;`
# separators) minus line 1 (`<name> () `), line 2 (`{ `), and the final line
# (`}`), i.e. exactly the text between the braces, one trailing newline.
#
# env_vars capture: setup_xbps_env unsets CFLAGS/CXXFLAGS/CPPFLAGS/LDFLAGS
# before pass 2, so any of the four that's set after sourcing is a
# template-level assignment; captured in that fixed order as space-separated
# "NAME=value" items (the composed string then vars-escaped like any value).
#
# External commands used: mktemp, mkdir, rm, mv. Everything else is bash.

LC_ALL=C
export LC_ALL
set -f # no globbing in the driver; setup_xbps_env restores it for sourcing

PROG="evaluate.sh"

die() {
    printf '%s: %s\n' "$PROG" "$*" >&2
    exit 1
}

# arguments
[ "$#" -eq 2 ] || die "usage: bash translator/evaluate.sh <srcpkg-dir> <dump-out-dir>"

SRCDIR=$(cd -- "$1" 2>/dev/null && pwd) || die "$1: not a readable directory"
TEMPLATE="$SRCDIR/template"
if [ ! -f "$TEMPLATE" ] || [ ! -r "$TEMPLATE" ]; then
    die "$TEMPLATE: no readable template"
fi

mkdir -p -- "$2" || die "$2: cannot create dump-out-dir"
OUTPARENT=$(cd -- "$2" 2>/dev/null && pwd) || die "$2: cannot resolve dump-out-dir"

# workspace
WORKDIR=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$WORKDIR"' EXIT

CNF_LOG="$WORKDIR/cnf.log"
STAGE="$WORKDIR/stage"          # dump staged here, installed only on success
SANDBOX1="$WORKDIR/sandbox1"    # empty cwd for pass 1
SANDBOX2="$WORKDIR/sandbox2"    # empty cwd for pass 2
NOPATH="$WORKDIR/nopath"        # empty; PATH while a template is sourced
mkdir "$STAGE" "$SANDBOX1" "$SANDBOX2" "$NOPATH" || die "cannot set up workspace"

# pass 2 stages the dump after PATH is neutralized: pin the one external
# command it needs by absolute path now
MKDIR=$(type -P mkdir) || die "mkdir not found on PATH"

# stub env
# Emulates a native x86_64/glibc build, mirroring xbps-src's setup enough for
# source-time evaluation. Also scrubs every variable the dump reads (and the
# templates append to) so nothing leaks in from the caller's environment.
# shellcheck disable=SC2034 # every "unused" variable here is read by the
#                            # sourced template, which shellcheck cannot see
setup_xbps_env() {
    set +f # templates are sourced with normal shell semantics
    unset pkgname version revision build_style build_helper distfiles \
        checksum hostmakedepends makedepends depends conflicts \
        configure_args make_build_args make_install_args \
        make_build_target make_install_target conf_files system_accounts \
        build_options build_options_default subpackages \
        CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
    local _leaked
    compgen -A variable build_option_ >"$WORKDIR/leaked.opts" || :
    while IFS= read -r _leaked; do
        unset "$_leaked"
    done <"$WORKDIR/leaked.opts"

    XBPS_TARGET_MACHINE="x86_64" XBPS_MACHINE="x86_64"
    XBPS_TARGET_WORDSIZE="64"     XBPS_WORDSIZE="64"
    XBPS_TARGET_LIBC="glibc"      XBPS_LIBC="glibc"
    XBPS_TARGET_ENDIAN="le"       XBPS_ENDIAN="le"
    XBPS_CHECK_PKGS=""
    CROSS_BUILD=""                XBPS_CROSS_BASE=""
    XBPS_MAKEJOBS=""              makejobs=""
    sourcepkg=""
    # harmless sentinels; only ever read at source time, never used as paths
    FILESDIR="/xbps-stub/files"   DESTDIR="/xbps-stub/destdir"
    wrksrc="/xbps-stub/wrksrc"    PKGDESTDIR="/xbps-stub/pkgdestdir"
    # distfile mirror macros, real URLs per common/environment/setup/misc.sh
    GNOME_SITE="https://download.gnome.org/sources"
    SOURCEFORGE_SITE="https://downloads.sourceforge.net/sourceforge"
    NONGNU_SITE="https://download.savannah.nongnu.org/releases"
    XORG_SITE="https://www.x.org/releases/individual"
    GNU_SITE="https://ftp.gnu.org/gnu"
    KERNEL_SITE="https://www.kernel.org/pub/linux"
    CPAN_SITE="https://www.cpan.org/modules/by-module"
    PYPI_SITE="https://files.pythonhosted.org/packages/source"
    DEBIAN_SITE="https://ftp.debian.org/debian/pool"
    FREEDESKTOP_SITE="https://freedesktop.org/software"
    KDE_SITE="https://download.kde.org/stable"
    MOZILLA_SITE="https://ftp.mozilla.org/pub"
    VIDEOLAN_SITE="https://download.videolan.org/pub/videolan"
    UBUNTU_SITE="http://archive.ubuntu.com/ubuntu/pool"
}

# vopt_* helpers, re-implemented from void-packages
# common/environment/setup/options.sh. vopt_bool / vopt_if / vopt_feature
# have to work; vopt_enable / vopt_with keep their real semantics too
# (strictly a superset of "present"); vopt_conflict is a no-op (option
# conflicts are Void's config concern; defaults never conflict).
# shellcheck disable=SC2317,SC2329 # invoked only by sourced templates
_vopt_set() {
    local _v="build_option_${1//-/_}"
    [ -n "${!_v-}" ]
}
# shellcheck disable=SC2317,SC2329
vopt_if() {
    if _vopt_set "$1"; then printf '%s' "${2-}"; else printf '%s' "${3-}"; fi
}
# shellcheck disable=SC2317,SC2329
vopt_with() {
    if _vopt_set "$1"; then printf -- '--with-%s' "${2:-$1}"
    else printf -- '--without-%s' "${2:-$1}"; fi
}
# shellcheck disable=SC2317,SC2329
vopt_enable() {
    if _vopt_set "$1"; then printf -- '--enable-%s' "${2:-$1}"
    else printf -- '--disable-%s' "${2:-$1}"; fi
}
# shellcheck disable=SC2317,SC2329
vopt_bool() {
    if _vopt_set "$1"; then printf -- '-D%s=true' "${2:-$1}"
    else printf -- '-D%s=false' "${2:-$1}"; fi
}
# shellcheck disable=SC2317,SC2329
vopt_feature() {
    if _vopt_set "$1"; then printf -- '-D%s=enabled' "${2:-$1}"
    else printf -- '-D%s=disabled' "${2:-$1}"; fi
}
# shellcheck disable=SC2317,SC2329
vopt_conflict() { :; }

# Any command bash can't resolve while sourcing is an unexpected helper:
# record it and let the caller turn it into a hard failure.
# shellcheck disable=SC2317,SC2329
command_not_found_handle() {
    printf '%s\n' "$1" >>"$CNF_LOG"
    return 127
}

# Hard failure if the template called anything we didn't stub.
check_unexpected_commands() {
    local _first
    if [ -s "$CNF_LOG" ]; then
        IFS= read -r _first <"$CNF_LOG" || _first="?"
        die "$TEMPLATE: unexpected command at source time: $_first"
    fi
}

# First line of a pass's captured stderr, for one-line failure reasons.
first_err_line() { # $1 = file; prints " (line)" or nothing
    local _line
    [ -s "$1" ] || return 0
    IFS= read -r _line <"$1" || return 0
    printf ' (%s)' "$_line"
}

# Escape a value for the vars file: backslash first, then tab, then newline.
_esc() { # $1 = raw value; result in $_esc_out
    _esc_out=${1//\\/\\\\}
    _esc_out=${_esc_out//$'\t'/\\t}
    _esc_out=${_esc_out//$'\n'/\\n}
}

# pass 1
# Discarded subshell: source with NO build_option_* set, only to harvest the
# declared options and their defaults (templates declare build_options *after*
# configure_args already used $(vopt_*), so pass-1 vopt output is wrong by
# construction and gets thrown away).
: >"$CNF_LOG"
(
    setup_xbps_env
    cd "$SANDBOX1" || exit 97
    # isolation: nothing but stub functions and builtins may resolve
    # while the untrusted template is sourced
    readonly PATH="$NOPATH"
    # shellcheck source=/dev/null
    if ! source "$TEMPLATE" >/dev/null 2>"$WORKDIR/p1.err"; then
        exit 96
    fi
    # sandbox purity: sourcing must not have created files in the cwd
    shopt -s nullglob dotglob
    _stray=("$SANDBOX1"/*)
    shopt -u nullglob dotglob
    [ "${#_stray[@]}" -eq 0 ] || exit 95
    printf '%s\n' "${build_options-}" >"$WORKDIR/p1.options"
    printf '%s\n' "${build_options_default-}" >"$WORKDIR/p1.defaults"
    exit 0
)
rc=$?
check_unexpected_commands
case $rc in
    0) ;;
    96) die "$TEMPLATE: template source error (pass 1)$(first_err_line "$WORKDIR/p1.err")" ;;
    95) die "$TEMPLATE: template wrote to the filesystem at source time" ;;
    97) die "internal: cannot enter sandbox (pass 1)" ;;
    *) die "$TEMPLATE: evaluation failed with status $rc (pass 1)" ;;
esac
if [ ! -f "$WORKDIR/p1.options" ] || [ ! -f "$WORKDIR/p1.defaults" ]; then
    die "$TEMPLATE: template exited during source (pass 1)"
fi

DECLARED_OPTIONS=$(<"$WORKDIR/p1.options")
DEFAULT_OPTIONS=$(<"$WORKDIR/p1.defaults")
DECLARED_OPTIONS=${DECLARED_OPTIONS//$'\n'/ }
DEFAULT_OPTIONS=${DEFAULT_OPTIONS//$'\n'/ }

# option names feed an eval and an indirect expansion: gate them hard
for _opt in $DECLARED_OPTIONS $DEFAULT_OPTIONS; do
    case "$_opt" in
        *[!A-Za-z0-9_-]*) die "$TEMPLATE: invalid build option name: $_opt" ;;
    esac
done

# pass 2
# Fresh subshell, defaults enabled, full dump staged to $STAGE/<pkgname>.
: >"$CNF_LOG"
(
    setup_xbps_env
    for _opt in $DEFAULT_OPTIONS; do
        eval "build_option_${_opt//-/_}=1"
    done

    # function inventory before sourcing (declare -F output is name-sorted;
    # here-strings need no /dev/fd, unlike process substitution)
    declare -A _had_fn=()
    while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        _had_fn["${_line#declare -f }"]=1
    done <<<"$(declare -F)"

    cd "$SANDBOX2" || exit 97
    # isolation, as in pass 1 (the staging below is builtins plus $MKDIR)
    readonly PATH="$NOPATH"
    # shellcheck source=/dev/null
    if ! source "$TEMPLATE" >/dev/null 2>"$WORKDIR/p2.err"; then
        exit 96
    fi
    [ -s "$CNF_LOG" ] && exit 94

    # sandbox purity: sourcing must not have created files in the cwd
    shopt -s nullglob dotglob
    _stray=("$SANDBOX2"/*)
    shopt -u nullglob dotglob
    [ "${#_stray[@]}" -eq 0 ] || exit 95

    # pkgname gates the dump directory name: reject anything unsafe
    case "${pkgname-}" in
        '') exit 93 ;;
        .|..|-*|*[!A-Za-z0-9._+-]*) exit 92 ;;
    esac

    _pkgdump="$STAGE/$pkgname"
    "$MKDIR" -p "$_pkgdump/functions" || exit 91

    # vars: the 20 pinned keys, always present, fixed order
    {
        for _key in pkgname version revision build_style build_helper \
            distfiles checksum hostmakedepends makedepends depends \
            conflicts configure_args make_build_args make_install_args \
            make_build_target make_install_target conf_files \
            system_accounts patch_args; do
            _esc "${!_key-}"
            printf '%s\t%s\n' "$_key" "$_esc_out"
        done
        # env_vars: the four flags were unset before sourcing (setup_xbps_env),
        # so set-after == template-level assignment; fixed order.
        _items=""
        for _key in CFLAGS CXXFLAGS CPPFLAGS LDFLAGS; do
            if [ "${!_key+set}" = "set" ]; then
                _items="${_items:+$_items }$_key=${!_key}"
            fi
        done
        _esc "$_items"
        printf '%s\t%s\n' env_vars "$_esc_out"
    } >"$_pkgdump/vars" || exit 91

    # options: resolved values for the declared set, declared order
    {
        for _opt in $DECLARED_OPTIONS; do
            _bo="build_option_${_opt//-/_}"
            if [ -n "${!_bo-}" ]; then
                printf '%s=1\n' "$_opt"
            else
                printf '%s=0\n' "$_opt"
            fi
        done
    } >"$_pkgdump/options" || exit 91

    # functions: new do_*/pre_*/post_*/*_package, bodies verbatim
    while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        _fn=${_line#declare -f }
        [ -n "${_had_fn[$_fn]-}" ] && continue
        case "$_fn" in
            do_*|pre_*|post_*|*_package) ;;
            *) continue ;;
        esac
        case "$_fn" in
            */*) exit 90 ;;   # would escape functions/; nothing sane does this
        esac
        declare -f "$_fn" >"$WORKDIR/fn.raw" || exit 90
        mapfile -t _fnlines <"$WORKDIR/fn.raw"
        # pinned shape: [0] "<name> () ", [1] "{ ", ..., [last] "}"
        _brace=${_fnlines[1]-}
        if [ "${#_fnlines[@]}" -lt 4 ] || [ "${_brace%% }" != "{" ] ||
            [ "${_fnlines[-1]}" != "}" ]; then
            exit 90
        fi
        printf '%s\n' "${_fnlines[@]:2:${#_fnlines[@]}-3}" \
            >"$_pkgdump/functions/$_fn" || exit 91
    done <<<"$(declare -F)"

    printf '%s\n' "$pkgname" >"$WORKDIR/pkgname" || exit 91
    : >"$WORKDIR/p2.ok"
    exit 0
)
rc=$?
check_unexpected_commands
case $rc in
    0) [ -f "$WORKDIR/p2.ok" ] ||
            die "$TEMPLATE: template exited during source (pass 2)" ;;
    96) die "$TEMPLATE: template source error (pass 2)$(first_err_line "$WORKDIR/p2.err")" ;;
    95) die "$TEMPLATE: template wrote to the filesystem at source time" ;;
    94) die "$TEMPLATE: unexpected command at source time" ;;
    93) die "$TEMPLATE: template sets no pkgname" ;;
    92) die "$TEMPLATE: unsafe pkgname" ;;
    91) die "internal: cannot write dump staging" ;;
    90) die "$TEMPLATE: cannot extract a function body" ;;
    97) die "internal: cannot enter sandbox (pass 2)" ;;
    *) die "$TEMPLATE: evaluation failed with status $rc (pass 2)" ;;
esac

# install the dump
IFS= read -r PKGNAME <"$WORKDIR/pkgname" || die "internal: pkgname not recorded"
case "$PKGNAME" in
    ''|.|..|-*|*/*|*[!A-Za-z0-9._+-]*) die "internal: unsafe pkgname escaped pass 2" ;;
esac
rm -rf -- "${OUTPARENT:?}/$PKGNAME"
mv -- "$STAGE/$PKGNAME" "$OUTPARENT/$PKGNAME" ||
    die "cannot write $OUTPARENT/$PKGNAME"
exit 0
