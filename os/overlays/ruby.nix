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
    version = "master-3d7820ef";
    src = super.fetchFromGitHub {
      owner = "nix-community";
      repo = "bundix";
      rev = "3d7820efdd77281234182a9b813c2895ef49ae1f";
      sha256 = "sha256-0CMDJR3xfewNuDthm3fEh6UPeRH9PURYxJ0PI1WPv4U=";
    };
  });

  osBundlerApp = super.callPackage ../packages/os-bundler-app {};
}
