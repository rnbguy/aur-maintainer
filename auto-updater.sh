#!/usr/bin/env bash

set -eu

[[ -z "${SSH_PRIV_KEY}" ]] && >&2 echo "no ssh private key" && exit
[[ -z "${ACTOR}" ]] && >&2 echo "no actor" && exit
[[ -z "${1}" ]] && [[ -f "${1}" ]] && >&2 echo "no csv file" && exit

CSV_FILE="${1}"

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
ssh aur@aur.archlinux.org list-repos

function latest_release() {
    curl -s "https://api.github.com/repos/${1}/releases/latest" \
    | jq -er .tag_name \
    | sed 's/^v//g'
}

function update() {
    [ -z $1 ] && >&2 echo "no package name is mentioned" && exit
    [ -z $2 ] && >&2 echo "no github project mentioned" && exit
    aur_name="$1"
    gh_handle="$2"
    version=$(latest_release "${gh_handle}") || (>&2 echo "[${aur_name}] GH API failed" && exit)
    git clone --depth 1 "ssh://aur@aur.archlinux.org/${aur_name}"
    chown -R pasudo "${aur_name}"
    cd "${aur_name}"
    sed -i "s/pkgver=.*$/pkgver=${version}/g" PKGBUILD
    if ! git diff --quiet; then
        sudo -u pasudo updpkgsums
        sudo -u pasudo makepkg --printsrcinfo > .SRCINFO
        git commit -am "$version" && git push && echo "[${aur_name}] updated to ${version}"
        git clean -fdx
    else
        echo "[${aur_name}] no update"
    fi
    cd - > /dev/null
}

echo "Running the auto updater.."

tail -n +2 "${CSV_FILE}" | while read line; do
    aur_name=$(cut -d, -f1 <<< "${line}")
    gh_handle=$(cut -d, -f2 <<< "${line}")
    update "${aur_name}" "${gh_handle}"
done
