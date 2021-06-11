import ../../make-test.nix (pkgs: {
  name = "osctl-exportfs-mount";

  description = ''
    Test osctl-exportfs exports and mounts
  '';

  machine = {
    disks = [
      { type = "file"; device = "sda.img"; size = "10G"; }
    ];

    config = {
      imports = [ ../../configs/base.nix ];

      boot.zfs.pools.tank = {
        layout = [
          { devices = [ "sda" ]; }
        ];
        doCreate = true;
        install = true;
      };

      services.nfs.server.enable = true;
      osctl.exportfs.enable = true;
    };
  };

  testScript = ''
    machine.start
    machine.wait_for_osctl_pool("tank")
    machine.wait_until_online

    machine.all_succeed(
      "osctl ct new --distribution alpine testct1",
      "osctl ct netif new bridge --link lxcbr0 --no-dhcp testct1 eth0",
      "osctl ct netif ip add testct1 eth0 192.168.1.21/24",
      "osctl ct set dns-resolver testct1 1.1.1.1",
      "osctl ct start testct1",
      "sleep 5",
      "osctl ct exec testct1 apk update",
      "osctl ct exec testct1 apk add nfs-utils",
      "osctl ct exec testct1 rc-service rpcbind start",
      "osctl ct exec testct1 rc-service rpc.statd start",

      "osctl ct new --distribution alpine testct2",
      "osctl ct netif new bridge --link lxcbr0 --no-dhcp testct2 eth0",
      "osctl ct netif ip add testct2 eth0 192.168.1.22/24",
      "osctl ct set dns-resolver testct2 1.1.1.1",
      "osctl ct start testct2",
      "sleep 5",
      "osctl ct exec testct2 apk update",
      "osctl ct exec testct2 apk add nfs-utils",
      "osctl ct exec testct2 rc-service rpcbind start",
      "osctl ct exec testct2 rc-service rpc.statd start",

      "mkdir -p /srv/server1",
      "echo hello > /srv/server1/server1.txt",

      "osctl-exportfs server new --address 10.0.0.10 server1",
      "osctl-exportfs export add --directory /srv/server1 --host 192.168.1.21/32 --options fsid=1234 server1",
      "osctl-exportfs server start server1",
    )

    sleep(10)

    machine.all_succeed(
      "osctl ct exec testct1 mkdir -p /mnt/server1",
      "osctl ct exec testct1 mount -v -t nfs 10.0.0.10:/srv/server1 /mnt/server1",
    )

    _, output = machine.succeeds("osctl ct exec testct1 cat /mnt/server1/server1.txt")

    if output.strip != "hello"
      fail "expected 'hello', got '#{out}'"
    end

    machine.succeeds("osctl ct exec testct2 mkdir -p /mnt/server1")
    machine.fails("osctl ct exec testct2 mount -v -t nfs 10.0.0.10:/srv/server1 /mnt/server1")
  '';
})
