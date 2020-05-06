self: super:
let
  mariadb-connector-c = super.mariadb-connector-c.overrideAttrs (oldAttrs: rec {
    name = "mariadb-connector-c-${version}";
    version = "3.1.7";

    src = super.fetchurl {
      url = "https://downloads.mariadb.org/interstitial/connector-c-${version}/mariadb-connector-c-${version}-src.tar.gz/from/http%3A//ftp.hosteurope.de/mirror/archive.mariadb.org/?serve";
      sha256 = "sha256:16pmdms454jbralaw6rpx0rjlf2297p6h3q8wfk0n87kbn7vrxv4";
      name   = "mariadb-connector-c-${version}-src.tar.gz";
    };
  });
in
{
  ruby = super.ruby_2_6;

  defaultGemConfig =
    super.callPackage (
      { lib, apparmor-parser, ncurses, openssl, zlib }:

      lib.mergeAttrs super.defaultGemConfig {
        curses = attrs: {
          buildInputs = [ ncurses ];
          buildFlags = [
            "--with-cflags=-I${ncurses.dev}/include"
            "--with-ldflags=-L${ncurses.out}/lib"
          ];
        };

        osctld = attrs: {
          buildInputs = [ apparmor-parser ];
        };

        mysql2 = attrs: {
          buildInputs = [ mariadb-connector-c zlib openssl ];
        };
      }) {};
}
