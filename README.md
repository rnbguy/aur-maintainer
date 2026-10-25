# aur-maintainer
Auto AUR packager maintainer for Github releases

CI installs runtime, build, and check dependencies as the unprivileged build user
before each package build. Dependencies are read from the generated
`.SRCINFO`, including dependencies specific to the current architecture.
Provider lookup resolves virtual dependencies to their AUR packages.
The target package is still built with `makepkg`, without installing it.

`EXCLUDED_PKGS` in `auto-updater.sh` lists packages excluded from release updates.
