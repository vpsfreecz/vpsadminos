{ pkgs, makeSystem }:
let
  inherit (pkgs) lib;
  effect = pkgs.writeShellScriptBin "runit-entry-effect" ''
    test "$RUNIT_ENTRY_ENV" = present || exit 2
    test "$(cat "$RUNIT_ENTRY_ROOT/cgroup/cgroup.procs")" = "$RUNIT_ENTRY_SHELL_PID" || exit 3
    printf 'body\n' >> "$RUNIT_ENTRY_ROOT/effects"
    exit "$RUNIT_ENTRY_EXIT"
  '';
  sv = pkgs.writeShellScriptBin "sv" ''
    test "$1" = once || exit 2
    test "$2" = entry-oneshot || exit 3
    test -f "$RUNIT_ENTRY_ROOT/done/done" || exit 4
    printf 'sv-once\n' >> "$RUNIT_ENTRY_ROOT/effects"
  '';
  fixture = makeSystem {
    modules = [
      {
        system.stateVersion = "26.05";
        boot.zfs.pools = { };
        runit.services = lib.genAttrs [ "entry-ordinary" "entry-oneshot" ] (name: {
          runlevels = [ ];
          path = [
            effect
            sv
          ];
          environment.RUNIT_ENTRY_ENV = "present";
          oneShot = name == "entry-oneshot";
          killMode = if name == "entry-ordinary" then "process" else "control-group";
          run =
            if name == "entry-ordinary" then
              ''
                false
                exec runit-entry-effect
              ''
            else
              ''
                runit-entry-effect
              '';
          check = "printf 'check-callback\\n'";
          finish = "printf 'finish-callback\\n'";
          control.hangup = "printf 'control-callback\\n'";
          log.enable = true;
          log.run = "printf 'log-callback\\n'";
        });
      }
    ];
  };
  cfg = fixture.config;
  generated = name: kind: cfg.environment.etc."runit/services/${name}/${kind}".source;
  checks = {
    noStorage = cfg.boot.zfs.pools == { };
    noRunlevels = lib.all (name: cfg.runit.services.${name}.runlevels == [ ]) [
      "entry-ordinary"
      "entry-oneshot"
    ];
    noLinks =
      !lib.any (name: lib.hasPrefix "runit/runsvdir/" name && lib.hasInfix "/entry-" name) (
        builtins.attrNames cfg.environment.etc
      );
    processMode = cfg.runit.services.entry-ordinary.killMode == "process";
    controlGroupMode = cfg.runit.services.entry-oneshot.killMode == "control-group";
    oneShotValues =
      !cfg.runit.services.entry-ordinary.oneShot && cfg.runit.services.entry-oneshot.oneShot;
    helpersAndLog =
      lib.all
        (
          name:
          cfg.runit.services.${name}.includeHelpers && lib.hasInfix "exec 2>&1" (generated name "run").text
        )
        [
          "entry-ordinary"
          "entry-oneshot"
        ];
    callbacks =
      lib.all
        (
          name:
          lib.hasInfix "check-callback" (generated name "check").text
          && lib.hasInfix "finish-callback" (generated name "finish").text
          && lib.hasInfix "control-callback" (generated name "control/h").text
          && lib.hasInfix "log-callback" (generated name "log/run").text
        )
        [
          "entry-ordinary"
          "entry-oneshot"
        ];
    finishModes =
      !lib.hasInfix "kill-cgroup" (generated "entry-ordinary" "finish").text
      && lib.hasInfix "kill-cgroup" (generated "entry-oneshot" "finish").text;
  };
  inputs = pkgs.writeText "runit-entry-inputs.json" (
    builtins.toJSON {
      inherit checks;
      scripts = lib.genAttrs [ "entry-ordinary" "entry-oneshot" ] (name: generated name "run");
    }
  );
in
assert lib.assertMsg (lib.all (value: value) (
  builtins.attrValues checks
)) "runit entry module projections failed";
pkgs.runCommand "runit-cgroup-entry-eval"
  {
    nativeBuildInputs = [
      fixture.pkgs.ruby
      pkgs.coreutils
    ];
  }
  ''
    ruby - ${inputs} <<'RUBY'
    require 'json'
    require 'tmpdir'
    require 'open3'

    inputs = JSON.parse(File.read(ARGV.fetch(0)))
    raise 'module projection refused' unless inputs.fetch('checks').values.all?(true)
    checks = 0
    Dir.mktmpdir('runit-entry-') do |workspace|
      %w[entry-ordinary entry-oneshot].each do |name|
        %w[success creation attachment].each do |kind|
          root = File.join(workspace, "#{name}-#{kind}")
          Dir.mkdir(root)
          source = File.read(inputs.fetch('scripts').fetch(name))
          cgroup = "/run/runit/cgroup.service/#{name}"
          done = "/run/service/#{name}"
          raise 'unexpected cgroup replacement count' unless source.scan(cgroup).length == 2
          raise 'unexpected done replacement count' unless source.scan(done).length == (name == 'entry-oneshot' ? 2 : 0)
          source = source.gsub(cgroup, File.join(root, 'cgroup')).gsub(done, File.join(root, 'done'))
          File.write(File.join(root, 'run'), source)
          File.chmod(0o700, File.join(root, 'run'))
          File.write(File.join(root, 'helpers'), <<~SHELL)
            test "$(cat "$RUNIT_ENTRY_ROOT/cgroup/cgroup.procs")" = "$$" || return 1
            printf 'helper\\n' >> "$RUNIT_ENTRY_ROOT/effects"
            export RUNIT_ENTRY_SHELL_PID=$$
          SHELL
          if kind == 'creation'
            File.write(File.join(root, 'cgroup'), 'blocked')
          elsif kind == 'attachment'
            Dir.mkdir(File.join(root, 'cgroup'))
            Dir.mkdir(File.join(root, 'cgroup', 'cgroup.procs'))
          end
          env = { 'RUNIT_ENTRY_ROOT' => root, 'RUNIT_ENTRY_ENV' => 'caller', 'RUNIT_ENTRY_EXIT' => '0' }
          _, stderr, status = Open3.capture3(env, File.join(root, 'run'), chdir: root)
          raise 'child did not exit normally' unless status.exited?
          effects_path = File.join(root, 'effects')
          effects = File.exist?(effects_path) ? File.readlines(effects_path, chomp: true) : []
          marker = File.join(root, 'done', 'done')
          if kind == 'success'
            raise 'successful entry exit changed' unless status.exitstatus == 0
            pid = Integer(File.read(File.join(root, 'cgroup', 'cgroup.procs')).strip, 10)
            raise 'entry did not record its owned child PID' unless pid == status.pid
            expected = name == 'entry-oneshot' ? %w[helper body sv-once] : %w[helper body]
            raise 'helper/body/done/sv ordering changed' unless effects == expected
            raise 'one-shot marker changed' unless File.exist?(marker) == (name == 'entry-oneshot')
          else
            raise 'entry refusal exit changed' unless status.exitstatus == 1
            label = kind == 'creation' ? 'runit: cgroup creation failed' : 'runit: cgroup attachment failed'
            other = kind == 'creation' ? 'runit: cgroup attachment failed' : 'runit: cgroup creation failed'
            raise 'wrong entry refusal diagnostic' unless stderr.lines.map(&:chomp).count(label) == 1 && !stderr.include?(other)
            raise 'entry refusal reached later effects' unless effects.empty? && !File.exist?(marker)
            if kind == 'creation'
              raise 'creation failure changed its blocker' unless File.read(File.join(root, 'cgroup')) == 'blocked'
            else
              raise 'attachment failure changed its blocker' unless File.directory?(File.join(root, 'cgroup', 'cgroup.procs'))
            end
          end
          checks += 1
        end
      end

      root = File.join(workspace, 'ordinary-exit')
      Dir.mkdir(root)
      source = File.read(inputs.fetch('scripts').fetch('entry-ordinary'))
      original = '/run/runit/cgroup.service/entry-ordinary'
      raise 'unexpected exit-case replacement count' unless source.scan(original).length == 2
      File.write(File.join(root, 'run'), source.gsub(original, File.join(root, 'cgroup')))
      File.chmod(0o700, File.join(root, 'run'))
      File.write(File.join(root, 'helpers'), "export RUNIT_ENTRY_SHELL_PID=$$\n")
      _, _, status = Open3.capture3({ 'RUNIT_ENTRY_ROOT' => root, 'RUNIT_ENTRY_EXIT' => '7' }, File.join(root, 'run'), chdir: root)
      raise 'ordinary exec exit status changed' unless status.exited? && status.exitstatus == 7
      raise 'ordinary exec body was skipped' unless File.read(File.join(root, 'effects')) == "body\n"
      checks += 1
    end
    puts "module_checks=#{inputs.fetch('checks').length} entry_checks=#{checks}"
    RUBY
    touch "$out"
  ''
