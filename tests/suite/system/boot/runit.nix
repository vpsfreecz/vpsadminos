import ../../../make-test.nix (
  { pkgs }:
  let
    scriptPathPackage = pkgs.writeShellScriptBin "runit-script-env-probe" ''
      set -e
      test "$RUNIT_SCRIPT_ENV" = present
      ${pkgs.coreutils}/bin/mkdir -p /run/runit-script-env
      ${pkgs.coreutils}/bin/touch "/run/runit-script-env/$1"
    '';
  in
  {
    name = "system-boot-runit";

    description = ''
      Test runit service generation
    '';

    tags = [ "ci" ];

    machine = import ../../../machines/vpsadminos/with-empty.nix {
      inherit pkgs;
      config = {
        runit.services.runit-script-env = {
          path = [ scriptPathPackage ];
          environment = {
            RUNIT_SCRIPT_ENV = "present";
          };
          run = ''
            runit-script-env-probe run
            exec ${pkgs.coreutils}/bin/sleep 3600
          '';
          finish = ''
            runit-script-env-probe finish
          '';
          check = ''
            runit-script-env-probe check
          '';
          control.hangup = ''
            runit-script-env-probe control
          '';
        };
      };
    };

    testScript = ''
      def expect_probe(name)
        status, output = machine.execute("test -f /run/runit-script-env/#{name}")
        expect(status).to eq(0), output
      end

      before(:suite) do
        machine.start
        machine.wait_for_service("runit-script-env")
      end

      describe 'runit service script environment', order: :defined do
        it 'passes path and environment to run scripts' do
          expect_probe("run")
        end

        it 'passes path and environment to check scripts' do
          expect_probe("check")
        end

        it 'passes path and environment to control scripts' do
          status, output = machine.execute("sv hup runit-script-env")
          expect(status).to eq(0), output

          machine.wait_until_succeeds("test -f /run/runit-script-env/control")
          expect_probe("control")
        end

        it 'passes path and environment to finish scripts' do
          status, output = machine.execute("sv down runit-script-env")
          expect(status).to eq(0), output

          machine.wait_until_succeeds("test -f /run/runit-script-env/finish")
          expect_probe("finish")
        end
      end
    '';
  }
)
