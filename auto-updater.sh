#!/usr/bin/env bash

set -euo pipefail

readonly AUR_HOST="aur.archlinux.org"
readonly AUR_SSH_BASE="ssh://aur@${AUR_HOST}"
readonly CI_SOURCE_PKGS=(git jq openssh pacman-contrib namcap)
readonly PASUDO_USER="pasudo"
readonly AUR_QUERY_DELAY_SECONDS=5

PASUDO=()
exit_code=0

validate_environment() {
    local required_tools=(curl jq git ssh)
    local tool

    # Check for required tools
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_error "Required tool not found: $tool"
            return 1
        fi
    done

    # Validate GITHUB_TOKEN is set
    if [[ -z "${GITHUB_TOKEN-}" ]]; then
        log_error "GITHUB_TOKEN is not set"
        return 1
    fi

    # Test GITHUB_TOKEN by making a simple API call
    if ! curl -fs -H "authorization: Bearer ${GITHUB_TOKEN}" https://api.github.com/user >/dev/null 2>&1; then
        log_error "GITHUB_TOKEN validation failed; token may be invalid or expired"
        return 1
    fi

    return 0
}

ensure_github_token() {
    if [[ -n "${CI-}" ]]; then
        [[ -n "${GITHUB_TOKEN-}" ]] || { log_error "GITHUB_TOKEN missing"; exit 1; }
        return
    fi

    if [[ -n "${GITHUB_TOKEN-}" ]]; then
        return
    fi

    if ! command -v gh >/dev/null 2>&1; then
        log_error "gh CLI missing; install GitHub CLI or set GITHUB_TOKEN"
        exit 1
    fi

    if ! GITHUB_TOKEN=$(gh auth token); then
        log_error "failed to read GITHUB_TOKEN from gh auth token"
        exit 1
    fi
}

aur_query() {
    local url="$1"
    local body

    if ! body=$(curl -fs "$url"); then
        return 1
    fi

    if ((AUR_QUERY_DELAY_SECONDS > 0)); then
        sleep "$AUR_QUERY_DELAY_SECONDS"
    fi

    printf '%s' "$body"
}

latest_gh_release() {
    curl -fsL "https://api.github.com/repos/${1}/releases/latest" \
        --header "authorization: Bearer ${GITHUB_TOKEN}"
}

latest_version() {
    latest_gh_release "$1" \
        | jq -er .tag_name \
        | sed 's/^v//g' \
        | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$'
}

# shellcheck disable=SC2329
cleanup_pkg_dir() {
    [[ -n "${PKG_CLEANUP_TARGET-}" ]] || return

    if [[ -n "${PKG_CLEANUP_PREVIOUS_DIR-}" && "$PWD" != "$PKG_CLEANUP_PREVIOUS_DIR" ]]; then
        cd "$PKG_CLEANUP_PREVIOUS_DIR" || true
    fi

    rm -rf "$PKG_CLEANUP_TARGET"
    unset PKG_CLEANUP_TARGET PKG_CLEANUP_PREVIOUS_DIR
}

log_info() {
    printf '%s\n' "$*"
}

log_error() {
    >&2 printf '%s\n' "$*"
}

fail_pkg() {
    local pkg="$1"
    shift || true
    exit_code=1
    log_error "[${pkg}] $*"
}

run_pkg_step() {
    local pkg="$1"
    local message="$2"
    shift 2 || true
    if ! "$@"; then
        fail_pkg "$pkg" "$message"
        return 1
    fi
}

run_as_pasudo() {
    if ((${#PASUDO[@]} > 0)); then
        "${PASUDO[@]}" "$@"
    else
        "$@"
    fi
}

setup_ci_environment() {
    if [[ -z "${CI-}" ]]; then
        return
    fi

    [[ -n "${SSH_PRIV_KEY-}" ]] || { log_error "no ssh private key"; exit 1; }
    [[ -n "${ACTOR-}" ]] || { log_error "no actor"; exit 1; }

    HOME=$(getent passwd "$(whoami)" | cut -d: -f6)
    pacman -Syu --quiet --noconfirm --needed --asdeps "${CI_SOURCE_PKGS[@]}"

    git config --global user.name "$ACTOR"
    git config --global user.email "ci@github"
    git config --global init.defaultBranch "master"

    useradd --create-home --system "$PASUDO_USER"
    echo 'aur ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/aur

    PASUDO=(sudo -u "$PASUDO_USER")

    mkdir -p ~/.ssh
    (umask 0077; echo "$SSH_PRIV_KEY" > ~/.ssh/aur 2> /dev/null)
    (umask 0077; ssh-keyscan "$AUR_HOST" >> ~/.ssh/known_hosts 2> /dev/null)
    eval "$(ssh-agent -s | sed '/^echo /d')"
    ssh-add -q ~/.ssh/aur
}

process_pkg() {
    local pkgname="$1"
    local srcinfo_blob ghpath old_ver new_ver srcinfo_url previous_dir pkg_clone_path

    srcinfo_url="https://aur.archlinux.org/cgit/aur.git/plain/.SRCINFO?h=${pkgname}"
    if ! srcinfo_blob=$(aur_query "$srcinfo_url"); then
        fail_pkg "$pkgname" "Fetching .SRCINFO failed"
        return 1
    fi

    ghpath=$(echo "$srcinfo_blob" | grep -oPm1 "(?<=https://github.com/)[^/]*/[^/]*")
    if [[ -z "$ghpath" ]]; then
        log_info "[${pkgname}] not a github project"
        return 0
    fi

    old_ver=$(echo "$srcinfo_blob" | grep -oP "pkgver = \\K.*$")
    if ! new_ver=$(latest_version "$ghpath"); then
        fail_pkg "$pkgname" "GH API failed"
        return 1
    fi

    if [[ -z "$new_ver" ]]; then
        log_info "[${pkgname}] no release found"
        latest_gh_release "$ghpath"
        return 0
    fi

    log_info "[${pkgname}] https://github.com/${ghpath} : ${old_ver} => ${new_ver}"

    if [[ "$old_ver" == "$new_ver" ]]; then
        log_info "[${pkgname}] no update"
        return 0
    fi

    previous_dir="$PWD"
    pkg_clone_path="${previous_dir}/${pkgname}"

    log_info "[${pkgname}] Updating"

    if ! run_pkg_step "$pkgname" "git clone failed" git clone --depth 1 "${AUR_SSH_BASE}/${pkgname}"; then
        return 1
    fi

    log_info "[${pkgname}] Cloned"

    PKG_CLEANUP_PREVIOUS_DIR="$previous_dir"
    PKG_CLEANUP_TARGET="$pkg_clone_path"
    trap 'cleanup_pkg_dir; trap - RETURN' RETURN

    if ((${#PASUDO[@]} > 0)); then
        if ! run_pkg_step "$pkgname" "chown failed" chown -R "$PASUDO_USER" "$pkg_clone_path"; then
            return 1
        fi
    else
        log_info "[${pkgname}] running locally; skipping ownership change"
    fi

    if ! cd "$pkg_clone_path"; then
        fail_pkg "$pkgname" "entering directory failed"
        return 1
    fi

    sed -i 's/pkgrel=.*$/pkgrel=1/' PKGBUILD
    sed -i "s/pkgver=.*$/pkgver=${new_ver}/" PKGBUILD

    if ! run_as_pasudo updpkgsums; then
        fail_pkg "$pkgname" "Updating checksums failed"
        return 1
    fi

    if ! run_as_pasudo makepkg --printsrcinfo > .SRCINFO; then
        fail_pkg "$pkgname" "generating .SRCINFO failed"
        return 1
    fi

    mapfile -t makedepends < <(grep -E '^\s*makedepends\s*=\s*' .SRCINFO | tr -d ' ' | cut -d'=' -f2 || true)
    if ((${#makedepends[@]} > 0)); then
        if [[ -n "${CI-}" ]]; then
            if ! pacman -Syu --quiet --noconfirm --asdeps --needed "${makedepends[@]}"; then
                fail_pkg "$pkgname" "installing makedepends failed"
                return 1
            fi
        else
            log_info "[${pkgname}] skipping makedepends install (requires root privileges)"
        fi
    fi

    if ! run_pkg_step "$pkgname" "makepkg failed" run_as_pasudo makepkg -sdc; then
        return 1
    fi

    if [[ -n "${CI-}" ]]; then
        if ! run_pkg_step "$pkgname" "chown root failed" chown -R root "$PKG_CLEANUP_TARGET"; then
            return 1
        fi
    else
        log_info "[${pkgname}] skipping chown back to root outside CI"
    fi

    if ! run_pkg_step "$pkgname" "git commit failed" git commit -am "$new_ver"; then
        return 1
    fi

    if ! run_pkg_step "$pkgname" "git push failed" git push; then
        return 1
    fi

    if ! run_pkg_step "$pkgname" "git clean failed" git clean -fdx; then
        return 1
    fi

    if ! run_pkg_step "$pkgname" "namcap failed" namcap -i PKGBUILD; then
        return 1
    fi

    log_info "[${pkgname}] updated to ${new_ver}"
    return 0
}

ensure_github_token
setup_ci_environment
validate_environment || exit 1

echo "Running the auto updater.."

while read -r pkgname; do
    process_pkg "$pkgname" || exit_code=1
done < <(ssh "aur@${AUR_HOST}" list-repos)

exit "$exit_code"
