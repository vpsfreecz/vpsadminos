self: super:
let
  mariadb-connector-c = super.mariadb-connector-c.overrideAttrs (oldAttrs: rec {
    name = "mariadb-connector-c-${version}";
    version = "3.3.4";

    src = super.fetchurl {
      url = "https://downloads.mariadb.com/Connectors/c/connector-c-${version}/mariadb-connector-c-${version}-src.tar.gz";
      sha256 = "sha256-SG5f35dqjn+t9YOukSEoZV4BOsV1+nmy0a8PuIJ6eO0=";
      name   = "mariadb-connector-c-${version}-src.tar.gz";
    };
  });
in
{
  ruby = super.ruby_3_2;

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

  bundix = super.bundix.overrideAttrs (oldAttrs: rec {
    name = "bundix-${version}";
    version = "master-1b7df693";
    src = super.fetchFromGitHub {
      owner = "nix-community";
      repo = "bundix";
      rev = "1b7df693f9660b4c27b16770b096094954c4aa9b";
      sha256 = "sha256-zJQKsC9sId+ui2wZ0nUaDRP1SmzrNTWoDJxUdLoATqI=";
    };
  });

  osBundlerApp = super.callPackage ../packages/os-bundler-app {};
}
