{ pkgs }:
let
  lib = pkgs.lib;

  nmdSrc = pkgs.fetchFromGitLab {
    name = "nmd";
    owner = "rycee";
    repo = "nmd";
    rev = "9751ca5ef6eb2ef27470010208d4c0a20e89443d";
    sha256 = "0rbx10n8kk0bvp1nl5c8q79lz1w0p1b8103asbvwps3gmqd070hi";
  };

  nmd = import nmdSrc { inherit pkgs; };

  # Make sure the used package is scrubbed to avoid actually
  # instantiating derivations.
  scrubbedPkgsModule = {
    imports = [
      {
        _module.args = {
          pkgs = lib.mkForce (nmd.scrubDerivations "pkgs" pkgs);
          pkgs_i686 = lib.mkForce { };
        };

        nixpkgs.system = lib.mkDefault builtins.currentSystem;
      }
    ];
  };

  osModulesDocs = nmd.buildModulesDocs {
    modules =
      import ../modules/module-list.nix
      ++ [ scrubbedPkgsModule ];
    moduleRootPaths = [ ./.. ];
    mkModuleUrl = path:
      "https://github.com/vpsfreecz/vpsadminos/blob/master/${path}#blob-path";
    channelName = "vpsadminos";
    docBook.id = "vpsadminos-options";
  };

  docs = nmd.buildDocBookDocs {
    pathName = "vpsadminos";
    modulesDocs = [ osModulesDocs ];
    documentsDirectory = ./.;
    chunkToc = ''
      <toc>
        <d:tocentry xmlns:d="http://docbook.org/ns/docbook" linkend="book-vpsadminos-manual"><?dbhtml filename="index.html"?>
          <d:tocentry linkend="ch-options"><?dbhtml filename="options.html"?></d:tocentry>
          <d:tocentry linkend="ch-tools"><?dbhtml filename="tools.html"?></d:tocentry>
        </d:tocentry>
      </toc>
    '';
  };
in {
  inherit nmdSrc;

  options = {
    json = osModulesDocs.json.override {
      path = "share/doc/vpsadminos/options.json";
    };
  };

  inherit (docs) manPages html;
}
