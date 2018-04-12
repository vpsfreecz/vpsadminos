{ config, options, lib, pkgs, utils, ... }:

let
  filterPrefixes = [
    "boot.specialFileSystems"
    "fileSystems"
    "krb5"
    "lib"
    "meta"
    "networking.firewall"
    "programs.ssh"
    "security.pam"
    "security.wrappers"
    "services.avahi"
    "services.cgmanager"
    "services.fprintd"
    "services.nscd"
    "services.samba"
    "services.sssd"
    "services.openssh.startWhenNeeded"
    "services.zfs"
    "swapDevices"
    "systemd"
    "users.ldap"
  ];

  isPrefixOf = prefix: string:
    builtins.substring 0 (builtins.stringLength prefix) string == prefix;

  anyPrefix = string:
    builtins.any (x: isPrefixOf x string) filterPrefixes;

  optionsListVisible = lib.filter (opt: opt.visible && !opt.internal && !(anyPrefix opt.name)) (lib.optionAttrSetToDocList options);

  # Replace functions by the string <function>
  substFunction = x:
    if builtins.isAttrs x then lib.mapAttrs (name: substFunction) x
    else if builtins.isList x then map substFunction x
    else if lib.isFunction x then "<function>"
    else x;

  optionsListDesc = lib.flip map optionsListVisible (opt: opt // {
    # Clean up declaration sites to not refer to the NixOS source tree.
    declarations = map stripAnyPrefixes opt.declarations;
  }
  // lib.optionalAttrs (opt ? example) { example = substFunction opt.example; }
  // lib.optionalAttrs (opt ? default) { default = substFunction opt.default; }
  // lib.optionalAttrs (opt ? type) { type = substFunction opt.type; });

  # We need to strip references to /nix/store/* from options,
  # including any `extraSources` if some modules came from elsewhere,
  # or else the build will fail.
  #
  # E.g. if some `options` came from modules in ${pkgs.customModules}/nix,
  # you'd need to include `extraSources = [ pkgs.customModules ]`
  prefixesToStrip = map (p: "${toString p}/") ([ ../../.. ]);
  stripAnyPrefixes = lib.flip (lib.fold lib.removePrefix) prefixesToStrip;

  # Custom "less" that pushes up all the things ending in ".enable*"
  # and ".package*"
  optionLess = a: b:
    let
      ise = lib.hasPrefix "enable";
      isp = lib.hasPrefix "package";
      cmp = lib.splitByAndCompare ise lib.compare
                                 (lib.splitByAndCompare isp lib.compare lib.compare);
    in lib.compareLists cmp a.loc b.loc < 0;

  # Customly sort option list for the man page.
  optionsList = lib.sort optionLess optionsListDesc;

  # Convert the list of options into an XML file.
  optionsXML = builtins.toFile "options.xml" (builtins.toXML optionsList);

  optionsDocBook = pkgs.runCommand "options-db.xml" {} ''
    optionsXML=${optionsXML}
    if grep /nixpkgs/nixos/modules $optionsXML; then
      echo "The manual appears to depend on the location of Nixpkgs, which is bad"
      echo "since this prevents sharing via the NixOS channel.  This is typically"
      echo "caused by an option default that refers to a relative path (see above"
      echo "for hints about the offending path)."
      exit 1
    fi
    ${pkgs.libxslt.bin}/bin/xsltproc \
      --stringparam revision '${config.system.osRevision}' \
      -o $out ${./options-to-docbook.xsl} $optionsXML
  '';

  fmtOption = {name, description, ...}: ''
    ${name}
      ${description}
    '';
  opts = lib.concatMapStringsSep "\n" fmtOption optionsListVisible;

  optsCombined = pkgs.runCommand "options-combined"
    { nativeBuildInputs = [ pkgs.libxml2.bin pkgs.libxslt.bin ];
    }
    ''
      chmod -R u+w .
      ln -s ${optionsDocBook} options-db.xml
      ln -s ${./manual.xml} manual.xml
      touch version
      ls -l
      pwd
      xmllint --xinclude --output $out manual.xml
    '';
in
{
  config.system.build.options = optionsDocBook; #pkgs.writeText "options.md" opts;
  config.system.build.optionsHTML = pkgs.runCommand "options.html" {} ''
    ${pkgs.haskellPackages.pandoc}/bin/pandoc -f docbook -t html5 ${optsCombined} > $out
  '';

  config.system.build.optionsMD = pkgs.runCommand "options.md" {} ''
    ${pkgs.haskellPackages.pandoc}/bin/pandoc -f docbook -t markdown ${optsCombined} > $out
  '';
  config.system.build.optionsC = optsCombined;
}

