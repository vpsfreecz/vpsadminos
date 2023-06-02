{ pkgs, config, lib, ... }:
with lib;
{
  options = {
    system.secretsDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Path to a directory containing secret keys and other files that should
        not be stored in the Nix store. The directory's base name has to be
        <literal>secrets</literal>.

        If the sandbox is enabled (<literal>nix.useSandbox = true;</literal>)
        on the build machine, you need to add your directory with secrets
        to <literal>nix.sandboxPaths</literal> and then set this option to the
        path within the sandbox. For example, if your secrets on the build
        machine are stored in <literal>/home/vpsadminos/secrets</literal>, you
        could set
        <literal>nix.sandboxPaths = [ "/secrets=/home/vpsadminos/secrets" ];</literal>
        on the build machine and <literal>system.secretsDir = "/secrets";</literal>
        in vpsAdminOS config.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = config.system.secretsDir == null
                    || (baseNameOf config.system.secretsDir) == "secrets";
        message = "Base name of system.secretsDir has to be 'secrets'";
      }
    ];
  };
}
