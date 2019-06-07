{ config, lib, pkgs, utils, ... }:
with lib;
let
  osctl = "${pkgs.osctl}/bin/osctl";

  createRepos = pool: repos: concatStringsSep "\n\n" (mapAttrsToList (repo: cfg: (
    let
      osctlPool = "${osctl} --pool ${pool}";

      enabledToStr = enabled: if enabled then "true" else "-";

    in ''
      ### Repository ${pool}:${repo}
      lines=( $(${osctlPool} repository show -H -o url,enabled ${repo} 2> /dev/null) )
      hasRepo=$?
      if [ "$hasRepo" == "0" ] ; then
        echo "Repository ${pool}:${repo} already exists"

        currentUrl="''${lines[0]}"
        currentEnabled="''${lines[1]}"

        if [ "${cfg.url}" != "$currentUrl" ] ; then
          echo "Reconfiguring URL to ${cfg.url}"
          ${osctlPool} repository set url ${repo} "${cfg.url}" || exit 1
        fi

        if [ "${enabledToStr cfg.enabled}" != "$currentEnabled" ] ; then
          ${if cfg.enabled then ''
          echo "Enabling repository"
          ${osctlPool} repository enable ${repo} || exit 1
          '' else ''
          echo "Disabling repository"
          ${osctlPool} repository disable ${repo} || exit 1
          ''}
        fi

      else
        echo "Creating repository ${pool}:${repo}"
        ${osctlPool} repository add ${repo} "${cfg.url}" || exit 1
        ${osctlPool} repository set attr ${repo} org.vpsadminos.osctl:declarative yes

        ${optionalString (!cfg.enabled) ''
        echo "Disabling repository"
        ${osctlPool} repository disable ${repo} || exit 1
        ''}
      fi
    '')) repos);
in
{
  type = {
    options = {
      url = mkOption {
        type = types.str;
        example = "https://images.vpsadminos.org";
        description = "HTTP URL to the remote repository";
      };

      enabled = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable/disable the repository.

          Disabled repositories are included in the system, but they are not
          search for images until reenabled, which may be done manually
          using <literal>osctl</literal>.
        '';
      };
    };
  };

  mkServices = pool: repos: mkIf (repos != {}) {
    "repositories-${pool}" = {
      run = ''
        waitForOsctld
        waitForOsctlEntity pool ${pool}
        ${createRepos pool repos}
        sv once repositories-${pool}
      '';

      log.enable = true;
      log.sendTo = "127.0.0.1";
    };
  };
}

