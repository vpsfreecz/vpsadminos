import ../../make-test.nix (
  { pkgs }:
  {
    name = "driver-nixos";

    description = ''
      Test the NixOS driver
    '';

    tags = [ "ci" ];

    machine = import ../../machines/nixos/basic.nix pkgs;

    testScript = ''
      def run_expect(name, expected)
        ret = yield

        if ret != expected
          fail "#{name} returned '#{ret.inspect}' instead of '#{expected.inspect}'"
        end

        ret
      end

      fail "machine running but not started" if machine.running?
      fail "machine booted but not started" if machine.booted?

      machine.start
      machine.wait_for_boot
      machine.wait_for_service("test-shell")

      fail "machine not running but should be" unless machine.running?
      fail "machine not booted but should be" unless machine.booted?

      run_expect("execute", [0, "hello\n"]) { machine.execute("echo hello") }
      run_expect("succeeds", [0, "root\n"]) { machine.succeeds("whoami") }
      run_expect("fails", [1, ""]) { machine.fails("false") }

      machine.wait_until_succeeds("true")
      machine.wait_until_fails("false")

      machine.mkdir("/tmp/osvm")
      machine.mkdir_p("/tmp/osvm/nested/dir")

      machine.fails("ls -l /tmp/osvm/nested/file")
      machine.push_file("/etc/hosts", "/tmp/osvm/nested/file", mkpath: true)
      machine.succeeds("ls -l /tmp/osvm/nested/file")

      pulled = machine.pull_file("/etc/os-release")

      unless File.exist?(pulled)
        fail "pulled file not found at '#{pulled}'"
      end

      machine.stop
      machine.wait_for_shutdown

      fail "machine running but was stopped" if machine.running?
      fail "machine booted but was stopped" if machine.booted?

      machine.start
      machine.wait_for_boot
      machine.wait_for_service("test-shell")
      machine.kill

      fail "machine running but was killed" if machine.running?
      fail "machine booted but was killed" if machine.booted?
    '';
  }
)
