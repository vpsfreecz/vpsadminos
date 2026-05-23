import ../../make-test.nix (
  { pkgs }:
  let
    mkScript = name: ''
      require 'fileutils'

      state_dir = File.dirname(machine.send(:console_log_path))
      ready_dir = File.join(state_dir, 'parallel-test-scripts')
      FileUtils.mkdir_p(ready_dir)

      @script_private = ${builtins.toJSON name}

      File.write(File.join(ready_dir, ${builtins.toJSON name}), "ready\n")
      File.open(File.join(ready_dir, 'shells.log'), 'a') do |f|
        f.puts(Thread.current[OsVm::Machine::SHELL_INDEX_KEY])
      end

      wait_for_block(name: 'parallel test scripts', timeout: 5) do
        File.exist?(File.join(ready_dir, 'a')) && File.exist?(File.join(ready_dir, 'b'))
      end

      raise 'script context leaked' unless @script_private == ${builtins.toJSON name}
    '';
  in
  {
    name = "driver-parallel-test-scripts";

    description = ''
      Test that test scripts can be run in parallel
    '';

    tags = [ "ci" ];

    machine = {
      config = null;
    };

    testScriptJobs = 2;

    testScripts = {
      a = {
        description = ''
          Parallel test script A
        '';
        script = mkScript "a";
      };

      b = {
        description = ''
          Parallel test script B
        '';
        script = mkScript "b";
      };
    };
  }
)
