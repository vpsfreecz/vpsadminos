{ distribution, version, setupScript }:
import ./base.nix {
  name = "lxd";
  description = "lxd in snap";
  inherit distribution version setupScript;
  preSetupScript = ''
    machine.succeeds("osctl user new --map 0:100000:524288 snapct")
  '';
  testScript = ''
    machine.all_succeed(
      "osctl ct exec snapct snap install lxd",
      "osctl ct exec snapct /snap/bin/lxd init --auto",

      # We have to run lxc launch from within a screen, as otherwise it hangs
      # and does nothing.
      "osctl ct exec snapct screen -d -m /bin/sh -c '/snap/bin/lxc launch ubuntu:22.04 u1 ; echo $? > /lxc.status'"
    )

    _, output = machine.wait_until_succeeds("osctl ct exec snapct cat /lxc.status")

    if output.strip != '0'
      fail "lxc launch failed with exit status #{output.inspect}"
    end

    sleep(15)

    _, output = machine.succeeds("osctl ct exec snapct /snap/bin/lxc info u1")

    if /Status: RUNNING/ !~ output
      fail "lxd container not running, lxc info output: #{output.inspect}"
    end

    if /Type: container/ !~ output
      fail "expected type container, lxc info output: #{output.inspect}"
    end
  '';
}
