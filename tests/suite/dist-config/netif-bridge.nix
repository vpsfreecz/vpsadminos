import ../../make-test.nix (
  { pkgs }:
  {
    name = "dist-config-netif-bridge";
    description = "Guest networkd owns static bridge addresses and default routes";
    tags = [ "ci" ];
    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      machine.start
      machine.wait_for_osctl_pool('tank')
      machine.wait_until_online
      ct = get_container_id
      machine.all_succeed(
        'ip address add 198.51.100.1/32 dev lo',
        'ip -6 address add 2001:db8:618::1/128 dev lo',
        'ip -6 address add fd00:618::1/64 dev lxcbr0',
        "osctl ct new --distribution arch #{ct}",
        "osctl ct unset start-menu #{ct}",
        "osctl ct netif new bridge --link lxcbr0 --no-dhcp --gateway-v4 192.168.1.1 --gateway-v6 fd00:618::1 #{ct} eth0",
        "osctl ct netif ip add #{ct} eth0 192.168.1.70/24",
        "osctl ct netif ip add #{ct} eth0 fd00:618::70/64",
        "osctl ct start #{ct}",
      )
      machine.wait_until_succeeds("osctl ct exec #{ct} true")
      machine.all_succeed(
        "osctl ct exec #{ct} systemctl is-system-running --wait",
        "osctl ct exec #{ct} systemctl is-active systemd-networkd.service",
        "osctl ct exec #{ct} grep -Fx Gateway=192.168.1.1 /etc/systemd/network/eth0.network",
        "osctl ct exec #{ct} grep -Fx Gateway=fd00:618::1 /etc/systemd/network/eth0.network",
        "osctl ct exec #{ct} ip -4 route show default | grep -F 'via 192.168.1.1 dev eth0'",
        "osctl ct exec #{ct} ip -6 route show default | grep -F 'via fd00:618::1 dev eth0'",
        "osctl ct exec #{ct} ping -c 1 198.51.100.1",
        "osctl ct exec #{ct} ping -6 -c 1 2001:db8:618::1",
        'ping -c 1 192.168.1.70',
        "osctl ct del -f --prune #{ct}",
      )
    '';
  }
)
