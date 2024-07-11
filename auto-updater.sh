#!/usr/bin/env bash

set -eu

PASUDO=""

if [[ -n "${CI-}" ]]; then
    [[ -z "${SSH_PRIV_KEY}" ]] && >&2 echo "no ssh private key" && exit
    [[ -z "${ACTOR}" ]] && >&2 echo "no actor" && exit

    HOME=$(getent passwd "$(whoami)" | cut -d: -f6)

    # install git, jq, openssh (ssh), pacman-contrib (updpkgsums)
    pacman -Syu --asdeps --needed --noconfirm git jq openssh pacman-contrib > /dev/null 2>&1

    git config --global user.name "${ACTOR}"
    git config --global user.email "ci@github"
    git config --global init.defaultBranch "master"

    # create non-sudo user
    useradd --system pasudo
    echo 'aur ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/aur
    PASUDO="sudo -u pasudo"

    # setup ssh
    mkdir -p ~/.ssh
    (umask 0077; echo "${SSH_PRIV_KEY}" > ~/.ssh/aur 2> /dev/null)
    (umask 0077; ssh-keyscan aur.archlinux.org >> ~/.ssh/known_hosts 2> /dev/null)
    eval "$(ssh-agent)" > /dev/null
    ssh-add ~/.ssh/aur > /dev/null 2>&1
fi

function latest_release() {
    curl -s "https://api.github.com/repos/${1}/releases/latest" \
    | jq -er .tag_name \
    | sed 's/^v//g'
}

echo "Running the auto updater.."

ssh aur@aur.archlinux.org list-repos | while read -r pkgname; do
    srcinfo_blob=$(curl -s "https://aur.archlinux.org/cgit/aur.git/plain/.SRCINFO?h=${pkgname}")
    # if ghpath=$(echo "${srcinfo_blob}" | grep -oPm1 "(?<=https://github.com/)[^/]*/[^/]*(?=/releases/download)"); then
    if ghpath=$(echo "${srcinfo_blob}" | grep -oPm1 "(?<=https://github.com/)[^/]*/[^/]*"); then
        old_ver=$(echo "${srcinfo_blob}" | grep -oP "pkgver = \K.*$")
        new_ver=$(latest_release "${ghpath}") || (>&2 echo "[${pkgname}] GH API failed" && exit)

        echo "[${pkgname}] https://github.com/${ghpath} : ${old_ver} => ${new_ver}"

        if [[ "${old_ver}" != "${new_ver}" ]]; then
            echo "[${pkgname}] Updating"
            git clone --depth 1 "ssh://aur@aur.archlinux.org/${pkgname}"
            echo "[${pkgname}] Cloned"
            chown -R pasudo "${pkgname}"
            cd "${pkgname}"
            sed -i "s/pkgrel=.*$/pkgrel=1/g" PKGBUILD
            sed -i "s/pkgver=.*$/pkgver=${new_ver}/g" PKGBUILD
            if ${PASUDO} updpkgsums; then
                ${PASUDO} makepkg --printsrcinfo > .SRCINFO
                grep '^\s*\(make\|\)depends =' .SRCINFO | tr -d ' ' | cut -d'=' -f2 | xargs pacman -Syu --asdeps --needed --noconfirm
                if ${PASUDO} makepkg -sdc && chown -R root "../${pkgname}" && git commit -am "$new_ver" && git push; then
                    echo "[${pkgname}] updated to ${new_ver}"
                else
                    >&2 echo "[${pkgname}] makepkg failed"
                fi
            else
                >&2 echo "[${pkgname}] Updating checksums failed"
            fi
            chown -R root "../${pkgname}" && git clean -fdx
            cd - > /dev/null
        else
            echo "[${pkgname}] no update"
        fi
    else
        echo "[${pkgname}] not a github project"
    fi
done
