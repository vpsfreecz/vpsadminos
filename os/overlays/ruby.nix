self: super:
let
  mariadb-connector-c = super.mariadb-connector-c.overrideAttrs (oldAttrs: rec {
    name = "mariadb-connector-c-${version}";
    version = "3.3.1";

    src = super.fetchurl {
      url = "https://downloads.mariadb.com/Connectors/c/connector-c-${version}/mariadb-connector-c-${version}-src.tar.gz";
      sha256 = "sha256-KZk/SuTJdWYnJJeHktGlA7nudg+7GU0yGnVCU8vmCq0=";
      name   = "mariadb-connector-c-${version}-src.tar.gz";
    };
  });
in
{
  ruby = super.ruby_2_7;

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

  osBundlerApp = super.callPackage ../packages/os-bundler-app {};
}
