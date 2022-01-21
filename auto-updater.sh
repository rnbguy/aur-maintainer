#!/usr/bin/env bash

set -eu

[[ -z "${SSH_PRIV_KEY}" ]] && >&2 echo "no ssh private key" && exit
[[ -z "${ACTOR}" ]] && >&2 echo "no actor" && exit

# install git, jq, openssh (ssh), pacman-contrib (updpkgsums)
2>&1 pacman -Syu git jq openssh pacman-contrib --asdeps --needed --noconfirm > /dev/null

git config --global user.name "${ACTOR}"
git config --global user.email "ci@github"

# create non-sudo user
useradd --system pasudo
echo 'aur ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/aur

# setup ssh
mkdir -p ~/.ssh
(umask 0077; echo "${SSH_PRIV_KEY}" > ~/.ssh/aur 2> /dev/null)
(umask 0077; ssh-keyscan aur.archlinux.org >> ~/.ssh/known_hosts 2> /dev/null)
eval $(ssh-agent) > /dev/null
2>&1 ssh-add ~/.ssh/aur > /dev/null

function latest_release() {
    curl -s "https://api.github.com/repos/${1}/releases/latest" \
    | jq -er .tag_name \
    | sed 's/^v//g'
}

echo "Running the auto updater.."

ssh aur@aur.archlinux.org list-repos | while read pkgname; do
    git clone --depth 1 "ssh://aur@aur.archlinux.org/${pkgname}"
    chown -R pasudo "${pkgname}"
    cd "${pkgname}"
    echo "[${pkgname}] trying to update"
    if ghpath="$(grep -oPm1 "(?<=https://github.com/)[^/]*/[^/]*(?=/releases/download)" .SRCINFO)"; then
        old_ver=$(grep -oP "pkgver = \K.*$" .SRCINFO)
        new_ver=$(latest_release "${ghpath}") || (>&2 echo "[${pkgname}] GH API failed" && exit)
        echo "[${pkgname}] https://github.com/${ghpath} : ${old_ver} => ${new_ver}"
        sed -i "s/pkgver=.*$/pkgver=${new_ver}/g" PKGBUILD
        if ! git diff --quiet; then
            sudo -u pasudo updpkgsums
            sudo -u pasudo makepkg --printsrcinfo > .SRCINFO
            git commit -am "$new_ver" && git push && echo "[${pkgname}] updated to ${new_ver}"
            git clean -fdx
        else
            echo "[${pkgname}] no update"
        fi
    else
        echo "[${pkgname}] not a github project"
    fi
    cd - > /dev/null
done
