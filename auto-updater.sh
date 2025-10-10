#!/usr/bin/env bash

set -eu

PASUDO=()

if [[ -n "${CI-}" ]]; then
    [[ -z "$SSH_PRIV_KEY" ]] && >&2 echo "no ssh private key" && exit
    [[ -z "$ACTOR" ]] && >&2 echo "no actor" && exit

    HOME=$(getent passwd "$(whoami)" | cut -d: -f6)

    # install git, jq, openssh (ssh), pacman-contrib (updpkgsums), namcap
    pacman -Syu --asdeps --needed --noconfirm git jq openssh pacman-contrib namcap > /dev/null 2>&1

    git config --global user.name "$ACTOR"
    git config --global user.email "ci@github"
    git config --global init.defaultBranch "master"

    # create non-sudo user
    useradd --create-home --system pasudo
    echo 'aur ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/aur
    PASUDO=(sudo -u pasudo)

    # setup ssh
    mkdir -p ~/.ssh
    (umask 0077; echo "$SSH_PRIV_KEY" > ~/.ssh/aur 2> /dev/null)
    (umask 0077; ssh-keyscan aur.archlinux.org >> ~/.ssh/known_hosts 2> /dev/null)
    eval "$(ssh-agent)" > /dev/null
    ssh-add ~/.ssh/aur > /dev/null 2>&1
fi

function latest_gh_release() {
    curl -s "https://api.github.com/repos/${1}/releases/latest" \
        --header "authorization: Bearer ${GITHUB_TOKEN}"
}

function latest_version() {
    latest_gh_release "$1" \
    | jq -er .tag_name \
    | sed 's/^v//g' \
    | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$'
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

push_pkg_dir() {
    local pkg="$1"
    if ! pushd "$pkg" > /dev/null; then
        fail_pkg "$pkg" "entering directory failed"
        return 1
    fi
}

pop_pkg_dir() {
    popd > /dev/null || true
}

run_as_pasudo() {
    if ((${#PASUDO[@]} > 0)); then
        "${PASUDO[@]}" "$@"
    else
        "$@"
    fi
}

echo "Running the auto updater.."

exit_code=0

while read -r pkgname; do
    srcinfo_blob=$(curl -s "https://aur.archlinux.org/cgit/aur.git/plain/.SRCINFO?h=${pkgname}")
    # if ghpath=$(echo "${srcinfo_blob}" | grep -oPm1 "(?<=https://github.com/)[^/]*/[^/]*(?=/releases/download)"); then
    if ghpath=$(echo "$srcinfo_blob" | grep -oPm1 "(?<=https://github.com/)[^/]*/[^/]*"); then
        old_ver=$(echo "$srcinfo_blob" | grep -oP "pkgver = \K.*$")
        if ! new_ver=$(latest_version "$ghpath"); then
            >&2 echo "[${pkgname}] GH API failed"
            exit_code=1
            continue
        fi

        if [[ "$new_ver" == "" ]]; then
            echo "[${pkgname}] no release found"
            latest_gh_release "$ghpath"
            continue
        fi

        echo "[${pkgname}] https://github.com/${ghpath} : ${old_ver} => ${new_ver}"

        if [[ "$old_ver" != "$new_ver" ]]; then
            log_info "[${pkgname}] Updating"
            if ! run_pkg_step "$pkgname" "git clone failed" git clone --depth 1 "ssh://aur@aur.archlinux.org/${pkgname}"; then
                continue
            fi
            log_info "[${pkgname}] Cloned"
            if ! run_pkg_step "$pkgname" "chown failed" chown -R pasudo "$pkgname"; then
                continue
            fi
            if ! push_pkg_dir "$pkgname"; then
                continue
            fi
            sed -i "s/pkgrel=.*$/pkgrel=1/g" PKGBUILD
            sed -i "s/pkgver=.*$/pkgver=${new_ver}/g" PKGBUILD

            if ! run_as_pasudo updpkgsums; then
                fail_pkg "$pkgname" "Updating checksums failed"
                pop_pkg_dir
                continue
            fi

            if ! run_as_pasudo makepkg --printsrcinfo > .SRCINFO; then
                fail_pkg "$pkgname" "generating .SRCINFO failed"
                pop_pkg_dir
                continue
            fi

            mapfile -t makedepends < <(grep -E '^\s*makedepends\s*=\s*' .SRCINFO | tr -d ' ' | cut -d'=' -f2)
            if ((${#makedepends[@]} > 0)); then
                if ! pacman -Syu --asdeps --needed --noconfirm "${makedepends[@]}"; then
                    fail_pkg "$pkgname" "installing makedepends failed"
                    pop_pkg_dir
                    continue
                fi
            fi

            if ! run_pkg_step "$pkgname" "makepkg failed" run_as_pasudo makepkg -sdc; then
                pop_pkg_dir
                continue
            fi
            if ! run_pkg_step "$pkgname" "chown root failed" chown -R root "../${pkgname}"; then
                pop_pkg_dir
                continue
            fi
            if ! run_pkg_step "$pkgname" "git commit failed" git commit -am "$new_ver"; then
                pop_pkg_dir
                continue
            fi
            if ! run_pkg_step "$pkgname" "git push failed" git push; then
                pop_pkg_dir
                continue
            fi
            if ! run_pkg_step "$pkgname" "git clean failed" git clean -fdx; then
                pop_pkg_dir
                continue
            fi
            if ! run_pkg_step "$pkgname" "namcap failed" namcap -i PKGBUILD; then
                pop_pkg_dir
                continue
            fi

            pop_pkg_dir
            log_info "[${pkgname}] updated to ${new_ver}"
        else
            echo "[${pkgname}] no update"
        fi
    else
        echo "[${pkgname}] not a github project"
    fi
done < <(ssh aur@aur.archlinux.org list-repos)

exit "$exit_code"
