let
  makeMachine = addr: {
    disks = [
      {
        type = "file";
        device = "{machine}-sda.img";
        size = "10G";
      }
    ];

    networks = [
      { type = "user"; }
      { type = "socket"; }
    ];

    config = {
      imports = [
        ../../configs/base.nix
        ../../configs/pool-tank.nix
      ];

      networking.custom = ''
        ip addr add ${addr}/24 dev eth1
        ip link set eth1 up
      '';

      networking.hosts = {
        "192.168.10.11" = [ "node1" ];
        "192.168.10.12" = [ "node2" ];
      };
    };
  };
in
import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctl-ct-send-recv";

    description = ''
      Test osctl ct send/recv
    '';

    tags = [ "ci" ];

    machines = {
      node1 = makeMachine "192.168.10.11";

      node2 = makeMachine "192.168.10.12";
    };

    testScript = ''
      machines.each_value(&:start)
      machines.each_value { |m| m.wait_for_osctl_pool('tank') }
      machines.each_value(&:wait_until_online)

      node1.wait_until_succeeds('ping -c 1 node2', timeout: 60)
      node2.wait_until_succeeds('ping -c 1 node1', timeout: 60)

      pubkeys = {}

      machines.each do |name, m|
        m.succeeds("osctl send key gen -t ed25519")

        _, pubkey = m.succeeds("cat $(osctl send key path public)")
        pubkeys[name] = pubkey.strip
      end

      node1.succeeds("echo \"#{pubkeys['node2']}\" | osctl receive authorized-keys add node2")
      node2.succeeds("echo \"#{pubkeys['node1']}\" | osctl receive authorized-keys add node1")

      ctid = get_container_id

      # Send ctid from node1 to node2
      node2.fails("osctl ct show #{ctid}")

      node1.all_succeed(
        "osctl ct new --distribution alpine #{ctid}",
        "osctl ct start #{ctid}",
        "osctl ct send #{ctid} node2"
      )

      state_on_node2 = 'unknown'

      30.times do
        state_on_node2 = node2.osctl_json("ct show #{ctid}")['state']
        break if state_on_node2 == 'running'

        sleep(1)
      end

      if state_on_node2 != 'running'
        raise "#{ctid} is not running on node2, current state is #{state_on_node2.inspect}"
      end

      node1.fails("osctl ct show #{ctid}")

      # Send ctid back to node1
      node2.succeeds("osctl ct send #{ctid} node1")

      state_on_node1 = 'unknown'

      30.times do
        state_on_node1 = node1.osctl_json("ct show #{ctid}")['state']
        break if state_on_node1 == 'running'

        sleep(1)
      end

      if state_on_node1 != 'running'
        raise "#{ctid} is not running on node1, current state is #{state_on_node1.inspect}"
      end

      node2.fails("osctl ct show #{ctid}")
    '';
  }
)
