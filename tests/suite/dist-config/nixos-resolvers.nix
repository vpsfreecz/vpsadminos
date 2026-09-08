import ../../make-test.nix (
  { pkgs }:
  {
    name = "dist-config-nixos-resolvers";
    description = "Resolver management on pinned NixOS guests without a guest rebuild";
    tags = [ "ci" ];
    machine = import ../../machines/vpsadminos/tank.nix pkgs;
    testScripts = builtins.listToAttrs (
      map
        ({ variant, version }: {
          name = "${variant}-${version}";
          value.script = ''
            machine.start unless machine.running?
            machine.wait_for_osctl_pool('tank')
            machine.wait_until_online
            ct = get_container_id
            machine.all_succeed(
              "osctl ct new --distribution nixos --version ${version} --variant ${variant} #{ct}",
              "osctl ct unset start-menu #{ct}",
              "osctl ct netif new routed #{ct} eth0",
              "osctl ct netif ip add #{ct} eth0 192.0.2.80/32",
              "osctl ct set dns-resolver #{ct} 192.0.2.53",
              "osctl ct start #{ct}",
            )
            machine.wait_until_succeeds('ping -c 1 192.0.2.80')
            machine.succeeds("osctl ct exec #{ct} systemctl is-system-running --wait")
            version = machine.succeeds("osctl ct exec #{ct} nixos-version")[1].strip
            expect(version).to start_with('${version}')
            generation = machine.succeeds("osctl ct exec #{ct} readlink /run/current-system")[1]
            init = machine.osctl_json("ct show #{ct}").fetch('init_pid')
            machine.all_succeed(
              "osctl ct set dns-resolver #{ct} 192.0.2.54",
              "osctl ct exec #{ct} grep -Fx 'nameserver 192.0.2.54' /etc/resolv.conf",
              "osctl ct unset dns-resolver #{ct}",
            )
            expect(machine.osctl_json("ct show #{ct}").fetch('dns_resolvers')).to be_nil
            machine.all_succeed(
              "osctl ct set dns-resolver #{ct} 192.0.2.55",
              "osctl ct exec #{ct} grep -Fx 'nameserver 192.0.2.55' /etc/resolv.conf",
              "osctl ct exec #{ct} systemctl is-active networking-setup.service",
              "osctl ct exec #{ct} systemctl is-system-running --wait",
              'ping -c 1 192.0.2.80',
            )
            expect(machine.osctl_json("ct show #{ct}").fetch('init_pid')).to eq(init)
            expect(machine.succeeds("osctl ct exec #{ct} readlink /run/current-system")[1]).to eq(generation)
            machine.succeeds("osctl ct del -f --prune #{ct}")
          '';
        })
        [
          {
            variant = "minimal";
            version = "22.11";
          }
          {
            variant = "impermanence";
            version = "24.05";
          }
        ]
    );
  }
)
