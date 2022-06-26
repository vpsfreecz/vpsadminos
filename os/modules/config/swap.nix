{ config, lib, pkgs, utils, ... }:

with utils;
with lib;

{
  imports = [
    <nixpkgs/nixos/modules/config/swap.nix>
  ];

  config = mkIf ((length config.swapDevices) != 0) {

    system.requiredKernelConfig = with config.lib.kernelConfig; [
      (isYes "SWAP")
    ];

    runit.services =
      let

        createSwapDevice = sw:
          assert sw.device != "";
          assert !(sw.randomEncryption.enable && lib.hasPrefix "/dev/disk/by-uuid"  sw.device);
          assert !(sw.randomEncryption.enable && lib.hasPrefix "/dev/disk/by-label" sw.device);
          let
            realDevice' = escapeSystemdPath sw.realDevice;
            path = [ pkgs.util-linux ] ++ optional sw.randomEncryption.enable pkgs.cryptsetup;
          in nameValuePair "swap-${sw.deviceName}" {
            run = ''
              export PATH="${concatMapStringsSep ":" (v: "${v}/bin") path}:$PATH"

              ${optionalString (config.services.haveged.enable && sw.randomEncryption.enable) ''
              waitForService haveged
              ''}

              ${optionalString (sw.size != null) ''
                currentSize=$(( $(stat -c "%s" "${sw.device}" 2>/dev/null || echo 0) / 1024 / 1024 ))
                if [ "${toString sw.size}" != "$currentSize" ]; then
                  fallocate -l ${toString sw.size}M "${sw.device}" ||
                    dd if=/dev/zero of="${sw.device}" bs=1M count=${toString sw.size}
                  if [ "${toString sw.size}" -lt "$currentSize" ]; then
                    truncate --size "${toString sw.size}M" "${sw.device}"
                  fi
                  chmod 0600 ${sw.device}
                  ${optionalString (!sw.randomEncryption.enable) "mkswap ${sw.realDevice}"}
                fi
              ''}
              ${optionalString sw.randomEncryption.enable ''
                cryptsetup plainOpen -c ${sw.randomEncryption.cipher} -d ${sw.randomEncryption.source} ${sw.device} ${sw.deviceName}
                mkswap ${sw.realDevice}
              ''}

              swapon ${sw.realDevice}
            '';

            finish = optionalString sw.randomEncryption.enable "${pkgs.cryptsetup}/bin/cryptsetup luksClose ${sw.deviceName}";

            oneShot = true;
            onChange = "ignore";

            log.enable = true;
            log.sendTo = "127.0.0.1";
          };

      in listToAttrs (map createSwapDevice config.swapDevices);

  };
}
