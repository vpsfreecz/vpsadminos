import ../../make-test.nix (
  { pkgs }:
  {
    name = "driver-named-shells";

    description = ''
      Test named machine shells
    '';

    tags = [ "ci" ];

    machines = {
      nixos = (import ../../machines/nixos/basic.nix pkgs) // {
        shells = [
          "first"
          "second"
        ];
      };

      vpsadminos = (import ../../machines/vpsadminos/empty.nix pkgs) // {
        shells = [
          "first"
          "second"
        ];
      };
    };

    testScript = ''
      def run_expect(name, expected)
        ret = yield

        if ret != expected
          fail "#{name} returned '#{ret.inspect}' instead of '#{expected.inspect}'"
        end

        ret
      end

      def run_shell_checks(machine, name)
        first_started = "/tmp/#{name}-named-shell-first-started"
        first_done = "/tmp/#{name}-named-shell-first-done"

        machine.start
        machine.wait_for_boot

        unless machine.shells.keys == ['first', 'second']
          fail "#{name}: unexpected shell names: #{machine.shells.keys.inspect}"
        end

        run_expect("#{name} named shell execute", [0, "first\n"]) do
          machine.shells['first'].execute('echo first')
        end

        run_expect("#{name} named shell symbol lookup", [0, "first\n"]) do
          machine.shells[:first].succeeds('echo first')
        end

        run_expect("#{name} machine shell keyword", [0, "second\n"]) do
          machine.succeeds('echo second', shell: 'second')
        end

        machine.fails('false', shell: :second)
        machine.wait_until_succeeds('true', shell: 'second')
        machine.wait_until_fails('false', shell: 'second')

        machine.succeeds("rm -f #{first_started} #{first_done}")

        first_thread = Thread.new do
          machine.shells['first'].succeeds(
            "touch #{first_started}; sleep 5; touch #{first_done}"
          )
        end

        machine.wait_until_succeeds("test -f #{first_started}", shell: 'second', timeout: 10)
        machine.succeeds("test ! -f #{first_done}", shell: 'second')
        run_expect("#{name} second shell while first is busy", [0, "second-free\n"]) do
          machine.succeeds('echo second-free', shell: 'second')
        end

        first_thread.value
        machine.succeeds("test -f #{first_done}", shell: 'second')
      end

      run_shell_checks(nixos, 'nixos')
      run_shell_checks(vpsadminos, 'vpsadminos')
    '';
  }
)
