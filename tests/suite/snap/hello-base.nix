{ distribution, version, setupScript }:
import ./base.nix {
  name = "hello";
  description = "snap hello-world";
  inherit distribution version setupScript;
  testScript = ''
    machine.succeeds("osctl ct exec snapct snap install hello-world")
    st, output = machine.succeeds("osctl ct exec snapct snap run hello-world")

    if output.strip != 'Hello World!'
      fail "snap run hello-world not working, output:\n#{output}"
    end
  '';
}
