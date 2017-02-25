#!/usr/bin/env bash
# global
NIX_PATH=nixpkgs=/root/.nix-defexpr/channels/nixos:nixos=/root/.nix-defexpr/channels/nixos/nixos
# local
#NIX_PATH=~:~/nixpkgs

function clone_config() {
    cfg=$( cat configuration.nix | grep -v "clone-config" )

    # first escape / to \/, then \n to \\n, then '' to ''', finally ${ to ''${
    esc_cfg="$( echo "${cfg}" | sed 's:/:\\/:g;' | sed ':a;N;$!ba;s/\n/\\n/g' | sed "s:'':''':g" | sed "s:\${:''\${:g" )"

    mkdir gen
    sed 's/{{{METANIX}}}/'"${esc_cfg}"'/' clone-config.nix.t > gen/clone-config.nix
}

clone_config

NIXOS_CONFIG=$(pwd)/configuration.nix nix-build -K '<nixos>' -A config.system.build.tarball
