{ pkgs }:
let
  lib = pkgs.lib;

  nmdSrc = pkgs.fetchFromGitHub {
    name = "nmd";
    owner = "vpsfreecz";
    repo = "nmd";
    rev = "1ba00b0fe2fbf89d8b314de62a1065a301681c0b";
    sha256 = "sha256-CINlbjDD7Yf2ZLLInOscMsY5IK6ac9eIfEdERTrvOwo=";
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

  isOsModule = path: lib.hasPrefix "os/" path;

  osModulesDocs = nmd.buildModulesDocs {
    modules =
      import ../modules/module-list.nix
      ++ [ scrubbedPkgsModule ];
    moduleRootPaths = [ ./../.. <nixpkgs> ];
    mkModuleUrl = path:
      if isOsModule path then
        "https://github.com/vpsfreecz/vpsadminos/blob/staging/${path}#blob-path"
      else
        "https://github.com/NixOS/nixpkgs/blob/master/${path}#blob-path";
    mkChannelPath = path:
      if isOsModule path then
        "vpsadminos/${path}"
      else
        "nixpkgs/${path}";
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
