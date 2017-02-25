prepare-fedora() {
    dnf -y install git curl bzip2 tar sudo
}

bootstrap-nix() {
    type dnf &>/dev/null && prepare-fedora

    useradd nix
    groupadd -r nixbld
    for n in $(seq 1 10); do
        useradd -c "Nix build user $n" \
                -d /var/empty -g nixbld -G nixbld -M -N -r -s "$(which nologin)" nixbld$n;
    done
    mkdir /nix
    chown -R nix /nix
    su -c "bash <(curl https://nixos.org/nix/install)" nix
    # source nix env
    . ~nix/.nix-profile/etc/profile.d/nix.sh
}

add-channels() {
    local chan=$1
    nix-channel --remove nixpkgs
    nix-channel --add "http://nixos.org/channels/nixos-${chan}" nixos
    nix-channel --update
}

build-nixos() {
    local chan=$1
    add-channels $chan

    cp "$BASEDIR"/files/configuration.nix "$INSTALL"/configuration.nix
    cp "$BASEDIR"/files/clone-config.nix.t "$INSTALL"/clone-config.nix.t
    cp "$BASEDIR"/files/build.sh "$INSTALL"/build.sh

    pushd "$INSTALL"
    ./build.sh | tee > build.log

    # extract short-hash from
    # /nix/store/gmka0y98lk7r32mb26id2473c9csj3zn-tarball
    shorthash="$( grep  "/nix/store/.*-tarball" build.log | cut -d'/' -f 4 | head -c 7 )"

    RELVER="$chan-$shorthash" # $(date +%Y%m%d)

    OUTPUT=$OUTPUT_PREFIX/$DISTNAME-$RELVER-x86_64-vpsfree${OUTPUT_SUFFIX}.tar.gz

    echo "Copying tarball to $OUTPUT ..."

    cp ./result/tarball/nixos-system-x86_64-linux.tar.xz $OUTPUT
    popd
}
