import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctl-exportfs-mount";

    description = ''
      Test osctl-exportfs exports and mounts
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { config, ... }:
        {
          services.nfs.server.enable = true;
          osctl.exportfs.enable = true;
        };
    };

    testScript = ''
      before(:suite) do
        machine.wait_for_osctl_pool("tank")
        machine.wait_until_online
      end

      describe "osctl-exportfs mount", order: :defined do
        before(:context) do
          machine.all_succeed(
            "osctl ct new --distribution alpine testct1",
            "osctl ct unset start-menu testct1",
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
            "osctl ct unset start-menu testct2",
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

          machine.wait_until_succeeds("test -s /run/osctl/exportfs/servers/server1/pid")
          @server_pid = machine.succeeds("cat /run/osctl/exportfs/servers/server1/pid")[1].strip

          machine.wait_until_succeeds(
            "timeout 10 rpcinfo -p 10.0.0.10 | grep -Eq '^[[:space:]]*100003[[:space:]]+[0-9]+[[:space:]]+tcp[[:space:]]' && " \
              "timeout 10 rpcinfo -p 10.0.0.10 | grep -Eq '^[[:space:]]*100005[[:space:]]+[0-9]+[[:space:]]+tcp[[:space:]]'",
            timeout: 180
          )
        end

        after(:context) do
          machine.execute(
            "pid=$(cat /run/osctl/exportfs/servers/server1/pid 2>/dev/null) && " \
            "rm -f /proc/$pid/root/run/current-system && " \
            "ln -s /nix/var/nix/profiles/system /proc/$pid/root/run/current-system || true"
          )
          machine.all_succeed(
            "osctl-exportfs server stop server1",
            "osctl-exportfs server del server1",
          )
        end

        it "mounts exports for allowed hosts" do
          machine.succeeds("osctl ct exec testct1 mkdir -p /mnt/server1")
          machine.wait_until_succeeds(
            "osctl ct exec testct1 timeout 20 mount -v -t nfs -o proto=tcp,timeo=10,retrans=2 10.0.0.10:/srv/server1 /mnt/server1",
            timeout: 180
          )

          expect(machine.succeeds("osctl ct exec testct1 cat /mnt/server1/server1.txt")[1].strip).to eq("hello")
        end

        it "keeps serving when current-system is broken" do
          # A running export server must not depend on the system generation
          # that was current when it started, because that generation can be
          # garbage-collected while existing NFS clients keep using the server.
          machine.all_succeed(
            "rm /proc/#{@server_pid}/root/run/current-system",
            "ln -s /nix/store/missing-system /proc/#{@server_pid}/root/run/current-system",
          )

          expect(machine.succeeds("readlink /proc/#{@server_pid}/root/run/current-system")[1].strip)
            .to eq("/nix/store/missing-system")
          expect(machine.succeeds("osctl ct exec testct1 cat /mnt/server1/server1.txt")[1].strip).to eq("hello")
        end

        it "updates exports when current-system is broken" do
          # Management commands enter the existing server namespace. They must
          # still resolve commands from the caller's packaged PATH even when
          # the server's /run/current-system link is stale.
          machine.all_succeed(
            "mkdir -p /srv/server2",
            "echo second > /srv/server2/server2.txt",
            "osctl-exportfs export add --directory /srv/server2 --host 192.168.1.21/32 --options fsid=5678 server1",
            "osctl ct exec testct1 mkdir -p /mnt/server2",
          )
          machine.wait_until_succeeds(
            "osctl ct exec testct1 timeout 20 mount -v -t nfs -o proto=tcp,timeo=10,retrans=2 10.0.0.10:/srv/server2 /mnt/server2",
            timeout: 180
          )

          expect(machine.succeeds("osctl ct exec testct1 cat /mnt/server2/server2.txt")[1].strip).to eq("second")
        end

        it "removes exports that are already missing from the running server" do
          machine.all_succeed(
            "mkdir -p /srv/server3",
            "echo third > /srv/server3/server3.txt",
            "osctl-exportfs export add --directory /srv/server3 --host 192.168.1.21/32 --options fsid=9012 server1",
            "exportfs=$(readlink -f $(command -v exportfs)) && " \
              "nsenter -t #{@server_pid} -m -n -r --wd=/ -- " \
              "$exportfs -u 192.168.1.21/32:/srv/server3",
            "osctl-exportfs export del --as /srv/server3 --host 192.168.1.21/32 server1",
            "! osctl-exportfs export ls server1 | grep -F 'as      = /srv/server3'",
            "mountpoint=$(readlink -f $(command -v mountpoint)) && " \
              "! nsenter -t #{@server_pid} -m -r --wd=/ -- $mountpoint -q /srv/server3",
          )
        end

        it "rejects mounts from disallowed hosts" do
          machine.succeeds("osctl ct exec testct2 mkdir -p /mnt/server1")

          expect(machine.fails("osctl ct exec testct2 timeout 20 mount -v -t nfs -o proto=tcp,timeo=10,retrans=2 10.0.0.10:/srv/server1 /mnt/server1")[0]).not_to eq(0)
        end
      end
    '';
  }
)
