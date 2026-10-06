{ pkgs, makeSystem }:
let
  inherit (pkgs) lib;
  common = {
    system.stateVersion = "26.05";
    osctld.settings.disabled_generation_test = "retained";
    boot.zfs.pools.tank = {
      install = false;
      properties."feature@block_cloning" = "disabled";
      datasets.proof.properties.mountpoint = "/mnt/osctld-disabled-proof";
    };
  };
  make =
    module:
    makeSystem {
      modules = [
        common
        module
      ];
    };
  omitted = make { };
  enabled = make { osctld.enable = true; };
  declarative = make { osctl.pools.tank = { }; };
  disabled = make { osctld.enable = false; };
  rescueOnly = make { runit.services.osctld.runlevels = [ "rescue" ]; };
  cfg = disabled.config;
  generatedRun = system: name: system.config.environment.etc."runit/services/${name}/run".source.text;
  poolRun = generatedRun disabled "pool-tank";
  enabledPoolRun = generatedRun enabled "pool-tank";
  service = system: {
    inherit (system.config.runit.services.osctld) runlevels onChange reloadMethod;
    restartTriggers = map toString (lib.flatten system.config.runit.services.osctld.restartTriggers);
  };
  refuses = module: !(builtins.tryEval (make module).config.system.build.toplevel.drvPath).success;
  checks = {
    defaultEnabled = omitted.config.osctld.enable;
    omissionEqualsTrue =
      generatedRun omitted "osctld" == generatedRun enabled "osctld"
      && generatedRun omitted "pool-tank" == enabledPoolRun
      && service omitted == service enabled;
    enabledRunlevel = enabled.config.runit.services.osctld.runlevels == [ "default" ];
    enabledCustomRunlevel = rescueOnly.config.runit.services.osctld.runlevels == [ "rescue" ];
    disabledRunlevels = cfg.runit.services.osctld.runlevels == [ ];
    noRunlevelLinks =
      !lib.any (name: lib.hasSuffix "/osctld" name && lib.hasPrefix "runit/runsvdir/" name) (
        builtins.attrNames cfg.environment.etc
      );
    retainedDefinition = generatedRun disabled "osctld" == generatedRun enabled "osctld";
    retainedSettings = cfg.osctld.settings == enabled.config.osctld.settings;
    retainedTools = lib.all (name: lib.elem disabled.pkgs.${name} cfg.environment.systemPackages) [
      "osctl"
      "osup"
      "svctl"
    ];
    rawPoolImport = lib.hasInfix "zpool import" poolRun && lib.hasInfix "Mounting datasets..." poolRun;
    retainedZfsSettings =
      cfg.boot.zfs.pools.tank == enabled.config.boot.zfs.pools.tank
      && lib.hasInfix "feature@block_cloning=disabled" poolRun
      && cfg.runit.services.pool-tank.oneShot;
    enabledAssociation = lib.all (text: lib.hasInfix text enabledPoolRun) [
      "org.vpsadminos.osctl:active"
      "waitForOsctld"
      "osctl pool import"
      "osctl pool install"
    ];
    enabledParallelSettings = lib.all (text: lib.hasInfix text (generatedRun declarative "pool-tank")) [
      "osctl pool set parallel-start tank 2"
      "osctl pool set parallel-stop tank 4"
    ];
    disabledAssociation =
      !lib.any (text: lib.hasInfix text poolRun) [
        "org.vpsadminos.osctl:active"
        "waitForOsctld"
        "osctlEntityExists"
        "osctl pool"
        "getKernelParam osctl.pools"
      ];
    validDisabledSystem = (builtins.tryEval cfg.system.build.toplevel.drvPath).success;
    refusesDeclarativePool = refuses {
      osctld.enable = false;
      osctl.pools.tank = { };
    };
    refusesExportfs = refuses {
      osctld.enable = false;
      osctl.exportfs.enable = true;
    };
    refusesInstall = refuses {
      osctld.enable = false;
      boot.zfs.pools.tank.install = lib.mkForce true;
    };
    refusesForcedMembership = refuses {
      osctld.enable = false;
      runit.services.osctld.runlevels = lib.mkForce [ "rescue" ];
    };
  };
  haltPackage =
    system:
    let
      matching = lib.filter (
        package: lib.getName package == "halt"
      ) system.config.environment.systemPackages;
    in
    assert lib.assertMsg (builtins.length matching == 1) "expected one owning installed halt package";
    builtins.head matching;
  shutdownInputs = pkgs.writeText "osctld-disabled-shutdown-inputs.json" (
    builtins.toJSON {
      halt = {
        omitted = haltPackage omitted;
        enabled = haltPackage enabled;
        disabled = haltPackage disabled;
      };
      stage3 = {
        omitted = omitted.config.environment.etc."runit/3".source;
        enabled = enabled.config.environment.etc."runit/3".source;
        disabled = disabled.config.environment.etc."runit/3".source;
      };
      shell = pkgs.stdenv.shell;
    }
  );
  projections = pkgs.writeText "osctld-disabled-projections.json" (
    builtins.unsafeDiscardStringContext (
      builtins.toJSON {
        inherit checks;
        services = {
          enabled = service enabled;
          disabled = service disabled;
          rescue = service rescueOnly;
        };
      }
    )
  );
in
assert lib.assertMsg (lib.all (result: result) (
  builtins.attrValues checks
)) "osctld-disabled module checks failed";
pkgs.runCommand "osctld-disabled-eval" { nativeBuildInputs = [ enabled.pkgs.ruby ]; } ''
  ruby - ${../os/modules/system/activation/switch-to-configuration.rb} ${projections} <<'RUBY'
  require 'tmpdir'
  require 'json'

  source_path, projection_path = ARGV
  source = File.read(source_path)
  definitions, entrypoint = source.split("\ncase ARGV[0]\n", 2)
  raise 'missing owning activation entrypoint' unless entrypoint
  eval(definitions, TOPLEVEL_BINDING, source_path)
  projections = JSON.parse(File.read(projection_path))

  # Use the owning service parser and restart calculation with actual module
  # projections; only filesystem locations and the external command are fixtures.
  class FixtureServices < Services
    def initialize(old_service, new_service, etc_path, skipped: false)
      @opts = { dry_run: false }
      protected_path = File.join(etc_path, 'protected-services.txt')
      File.write(protected_path, skipped ? "osctld\n" : "")
      @protected_list = ServiceNameList.new(protected_path)
      @old_cfg = { 'defaultRunlevel' => 'default', 'services' => { 'osctld' => old_service } }
      @new_cfg = { 'defaultRunlevel' => 'default', 'services' => { 'osctld' => new_service } }
      @old_runlevel = 'default'
      @new_runlevel = get_runlevel(@new_cfg, @old_runlevel)
      @old_services = get_services(@old_cfg, @old_runlevel, etc_path)
      @new_services = get_services(@new_cfg, @new_runlevel, etc_path)
    end
  end

  class FixtureConfiguration < Configuration
    attr_reader :commands

    def initialize(**opts)
      super
      @commands = []
    end

    def system(*args)
      commands << args
      true
    end
  end

  Dir.mktmpdir('osctld-disabled-activation-') do |etc_path|
    run_path = File.join(etc_path, 'runit/services/osctld/run')
    FileUtils.mkdir_p(File.dirname(run_path))
    File.write(run_path, 'actual service path fixture')
    enabled = projections.fetch('services').fetch('enabled')
    changed = enabled.merge('restartTriggers' => ['changed-trigger'])
    cases = [
      ['selected', enabled, false, false, true],
      ['restarted', changed, false, false, false],
      ['skipped restart', changed, true, false, true],
      ['disabled', projections.fetch('services').fetch('disabled'), false, false, false],
      ['other runlevel', projections.fetch('services').fetch('rescue'), false, false, false],
      ['dry run', enabled, false, true, false]
    ]
    cases.each do |label, selected, skipped, dry_run, should_activate|
      services = FixtureServices.new(enabled, selected, etc_path, skipped: skipped)
      configuration = FixtureConfiguration.new(dry_run: dry_run)
      configuration.send(:activate_osctl, services)
      expected = should_activate ? [[File.join(Configuration::CURRENT_BIN, 'osctl'), 'activate', '--system']] : []
      raise "incorrect activation: #{label}" unless configuration.commands == expected
    end
    puts "module_checks=#{projections.fetch('checks').length} activation_checks=#{cases.length}"
  end
  RUBY
  ruby - ${shutdownInputs} <<'RUBY'
  require 'json'
  require 'open3'
  require 'rbconfig'
  require 'stringio'
  require 'tmpdir'
  require 'fileutils'

  inputs = JSON.parse(File.read(ARGV.fetch(0)))
  entrypoint = "\nhalt = Halt.new(File.basename($0), ARGV)\nhalt.run\n"
  classes = {}
  scripts = {}
  inputs.fetch('halt').each do |policy, package|
    script = File.realpath(File.join(package, 'bin/halt'))
    %w[poweroff reboot].each do |name|
      raise 'halt alias does not select installed script' unless File.realpath(File.join(package, 'bin', name)) == script
    end
    source = File.read(script)
    raise 'unexpected owning halt entrypoint' unless source.end_with?(entrypoint) && source.scan(entrypoint).length == 1
    scope = Module.new
    scope.module_eval(source.delete_suffix(entrypoint), script, 1)
    classes[policy] = scope.const_get(:Halt)
    scripts[policy] = source
  end
  raise 'omitted and enabled halt scripts differ' unless scripts.fetch('omitted') == scripts.fetch('enabled')
  raise 'incorrect generated halt policy' unless classes.fetch('omitted')::OSCTLD_ENABLED == true &&
                                              classes.fetch('enabled')::OSCTLD_ENABLED == true &&
                                              classes.fetch('disabled')::OSCTLD_ENABLED == false

  class CapturedHaltChild < StandardError; end
  class CapturedRunitDispatch < StandardError; end

  # Capture external effects only. The installed class owns option parsing,
  # reason/confirmation/countdown, hooks, shutdown/abort and final dispatch.
  def observe_halt(klass, name:, args:, loaded: false, listing: true, shutdown_status: 0,
                   interrupt: false, hooks: true, stale_status: false)
    events = []
    children = {}
    originals = {}
    original_streams = [$stdin, $stdout, $stderr]
    fields = %w[HALT_HOOK HALT_ACTION HALT_REASON HALT_FORCE HALT_KEXEC HALT_REASON_FILE]
    original_env = fields.to_h { |key| [key, ENV[key]] }
    original_spawn = Process.method(:spawn)
    original_wait = Process.method(:wait)
    original_write = File.method(:write)
    original_stat = File.method(:stat)
    original_unlink = File.method(:unlink)
    original_open = File.method(:open)
    original_tempfile = Tempfile.method(:new)
    output = StringIO.new
    error_output = StringIO.new
    failure = nil
    patch = lambda do |owner, method, &replacement|
      originals[[owner, method]] = owner.method(method)
      owner.define_singleton_method(method, &replacement)
    end

    Dir.mktmpdir('halt-effects-') do |private_dir|
      child_kind = nil
      in_child = false
      interrupted = false
      private_file = ->(path) { path.start_with?(private_dir + '/') }
      fake_stat = Object.new
      fake_stat.define_singleton_method(:file?) { true }
      fake_stat.define_singleton_method(:executable?) { true }
      text_stat = Object.new
      text_stat.define_singleton_method(:file?) { true }
      text_stat.define_singleton_method(:executable?) { false }
      logger = Object.new
      logger.define_singleton_method(:info) { |text| events << [:log, text] }

      begin
        $stdin = StringIO.new("fixture-host\n")
        $stdout = output
        $stderr = error_output
        patch.call(Syslog::Logger, :new) { |tag| raise 'unexpected logger' unless tag == 'halt'; logger }
        patch.call(Socket, :gethostname) { events << [:hostname]; 'fixture-host' }
        patch.call(Tempfile, :new) { |prefix| original_tempfile.call(prefix, private_dir) }
        patch.call(Dir, :entries) do |path|
          case path
          when klass::HOOK_DIR then hooks ? ['fixture-hook'] : []
          when klass::REASON_TEMPLATE_DIR then ['fixture-reason']
          else raise 'unexpected directory effect'
          end
        end
        patch.call(File, :stat) do |path|
          if path == File.join(klass::HOOK_DIR, 'fixture-hook')
            fake_stat
          elsif path == File.join(klass::REASON_TEMPLATE_DIR, 'fixture-reason')
            text_stat
          elsif private_file.call(path)
            original_stat.call(path)
          else
            raise 'unexpected stat effect'
          end
        end
        patch.call(File, :read) do |path|
          case path
          when '/sys/kernel/kexec_loaded' then loaded ? "1\n" : "0\n"
          when File.join(klass::REASON_TEMPLATE_DIR, 'fixture-reason')
            events << [:reason_template]
            "fixture template\n"
          else raise 'unexpected read effect'
          end
        end
        patch.call(File, :open) do |path, *arguments, **options, &block|
          if private_file.call(path)
            original_open.call(path, *arguments, **options, &block)
          else
            raise 'unexpected open effect' unless path == '/etc/runit/kexec' && arguments == ['w'] && options.empty? && !block
            events << [:kexec_marker]
            StringIO.new
          end
        end
        patch.call(File, :chmod) do |mode, path|
          raise 'unexpected chmod effect' unless path == '/etc/runit/kexec' && mode == 0o100
          events << [:kexec_chmod, mode]
          1
        end
        patch.call(File, :unlink) do |path|
          if path == '/run/osctl/shutdown'
            events << [:abort_marker]
            raise Errno::ENOENT
          end
          raise 'unexpected unlink effect' unless private_file.call(path)
          original_unlink.call(path)
        end
        patch.call(Kernel, :system) do |*command|
          case command
          when ['osctl', 'ct', 'ls', '-S', 'running']
            events << [:list]
            listing
          when ['osctl', 'shutdown', '--abort']
            events << [:abort]
            true
          else
            raise 'unexpected system effect' unless command.length == 2 && private_file.call(command.last)
            events << [:editor]
            original_write.call(command.last, "fixture reason\n")
            true
          end
        end
        patch.call(Kernel, :exec) do |*command, **options|
          raise 'unexpected exec effect' unless in_child && command.take(3) == ['osctl', 'shutdown', '--force'] && options == { pgroup: true }
          child_kind = :shutdown
          events << [:shutdown, command]
          raise CapturedHaltChild
        end
        patch.call(Process, :exec) do |*command|
          if in_child && command == [File.join(klass::HOOK_DIR, 'fixture-hook')]
            child_kind = :hook
            events << [:hook, fields.to_h { |key| [key, ENV[key]] }]
            raise CapturedHaltChild
          end
          raise 'unexpected process exec effect' unless !in_child && command.first == 'runit-init' && %w[0 6].include?(command.last) && command.length == 2
          events << [:dispatch, command.last]
          raise CapturedRunitDispatch
        end
        patch.call(Process, :fork) do |&body|
          raise 'missing owning fork body' unless body
          saved_env = fields.to_h { |key| [key, ENV[key]] }
          begin
            child_kind = nil
            in_child = true
            body.call
            raise 'owning child did not exec'
          rescue CapturedHaltChild
            raise 'unknown child effect' unless %i[hook shutdown].include?(child_kind)
          ensure
            in_child = false
            saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
          end
          status = child_kind == :shutdown ? shutdown_status : 0
          pid = original_spawn.call(RbConfig.ruby, '-e', "exit #{status}")
          children[pid] = child_kind
          events << [:fork, child_kind, pid]
          pid
        end
        patch.call(Process, :wait) do |pid|
          kind = children.fetch(pid)
          events << [:wait, kind, pid]
          if interrupt && kind == :shutdown && !interrupted
            interrupted = true
            raise Interrupt
          end
          result = original_wait.call(pid)
          children.delete(pid)
          result
        end

        if stale_status
          pid = original_spawn.call(RbConfig.ruby, '-e', 'exit 7')
          original_wait.call(pid)
          raise 'failed status fixture not established' unless $?.exitstatus == 7
        end
        object = klass.new(name, args)
        object.define_singleton_method(:sleep) { |seconds| events << [:sleep, seconds] }
        object.run
        raise 'owning halt returned without final dispatch'
      rescue CapturedRunitDispatch
        # The terminal exec is the captured end of a successful owning run.
      rescue StandardError, SystemExit => error
        failure = error
      ensure
        originals.to_a.reverse_each { |(owner, method), original| owner.define_singleton_method(method, original) }
        $stdin, $stdout, $stderr = original_streams
        original_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        children.each_key { |pid| original_wait.call(pid) }
      end
    end
    { events: events, output: output.string, error_output: error_output.string, failure: failure }
  end

  def check_halt(label)
    yield
  rescue StandardError => error
    raise "halt check failed: #{label}: #{error.message}"
  end

  def require_effect(condition, label)
    raise label unless condition
  end

  halt_checks = 0
  %w[omitted enabled disabled].each do |policy|
    %w[halt poweroff reboot].each do |name|
      check_halt("#{policy} forced #{name}") do
        result = observe_halt(classes.fetch(policy), name: name, args: ['--force', '--message', 'fixture message'])
        events = result.fetch(:events)
        require_effect(result.fetch(:failure).nil?, 'unexpected failure')
        require_effect(events.last == [:dispatch, name == 'reboot' ? '6' : '0'], 'wrong final dispatch')
        require_effect(events.count { |entry| entry.first == :shutdown } == (policy == 'disabled' ? 0 : 1), 'wrong shutdown selection')
        require_effect(events.none? { |entry| %i[list hostname sleep abort abort_marker].include?(entry.first) }, 'forced interactive/abort effect')
        hook_events = events.select { |entry| entry.first == :hook }
        require_effect(hook_events.map { |entry| entry.last.fetch('HALT_HOOK') } == %w[pre-run pre-system], 'hook order')
        require_effect(hook_events.all? { |entry| entry.last.fetch('HALT_FORCE') == '1' && entry.last.fetch('HALT_ACTION') == (name == 'reboot' ? 'reboot' : 'poweroff') }, 'hook environment')
        log_index = events.index { |entry| entry.first == :log }
        pre_system_index = events.index { |entry| entry.first == :hook && entry.last.fetch('HALT_HOOK') == 'pre-system' }
        require_effect(log_index && log_index < pre_system_index, 'common log/hook order')
        if policy != 'disabled'
          require_effect(events.find { |entry| entry.first == :shutdown }.last == %w[osctl shutdown --force --wall --message] + ['fixture message'], 'wall/message arguments')
          shutdown_index = events.index { |entry| entry.first == :shutdown }
          require_effect(log_index < shutdown_index && shutdown_index < pre_system_index, 'shutdown order')
        end
      end
      halt_checks += 1
    end
  end

  %w[enabled disabled].each do |policy|
    check_halt("#{policy} interactive reason") do
      result = observe_halt(classes.fetch(policy), name: 'poweroff', args: [])
      events = result.fetch(:events)
      require_effect(result.fetch(:failure).nil?, 'unexpected failure')
      require_effect(events.count { |entry| entry.first == :list } == (policy == 'enabled' ? 1 : 0), 'listing selection')
      require_effect(events.count { |entry| entry.first == :shutdown } == (policy == 'enabled' ? 1 : 0), 'shutdown selection')
      require_effect(events.include?([:reason_template]) && events.include?([:editor]) && events.include?([:hostname]), 'reason/confirmation missing')
      require_effect(events.count { |entry| entry == [:sleep, 1] } == 10, 'countdown changed')
      require_effect(result.fetch(:output).include?(policy == 'enabled' ? 'sent to logged-in container users' : 'written to system log'), 'reason notice missing')
      require_effect(!result.fetch(:output).include?('sent to logged-in container users') || policy == 'enabled', 'disabled wall promise')
      require_effect(events.last == [:dispatch, '0'], 'wrong final dispatch')
      require_effect(events.none? { |entry| %i[abort abort_marker].include?(entry.first) }, 'unexpected abort')
    end
    halt_checks += 1
  end

  check_halt('disabled unrelated failed process status') do
    result = observe_halt(classes.fetch('disabled'), name: 'poweroff', args: ['-f', '-m', 'fixture'], hooks: false, stale_status: true)
    require_effect(result.fetch(:failure).nil? && result.fetch(:events).last == [:dispatch, '0'], 'prior status affected dispatch')
    require_effect(result.fetch(:events).none? { |entry| %i[fork wait shutdown abort abort_marker].include?(entry.first) }, 'disabled process effect')
    require_effect(result.fetch(:output).include?('Executing pre-run hooks') && result.fetch(:output).include?('Executing pre-system hooks'), 'common hooks skipped')
  end
  halt_checks += 1

  check_halt('enabled listing refusal') do
    result = observe_halt(classes.fetch('enabled'), name: 'poweroff', args: ['-m', 'fixture'], listing: false)
    require_effect(result.fetch(:failure).is_a?(RuntimeError) && result.fetch(:failure).message == 'Unable to list containers', 'listing failure lost')
    require_effect(result.fetch(:events).none? { |entry| %i[shutdown dispatch].include?(entry.first) }, 'effect after listing refusal')
  end
  halt_checks += 1

  check_halt('enabled shutdown status refusal') do
    result = observe_halt(classes.fetch('enabled'), name: 'poweroff', args: ['-f', '-m', 'fixture'], shutdown_status: 7)
    require_effect(result.fetch(:failure).is_a?(RuntimeError) && result.fetch(:failure).message == 'Unable to shutdown osctld', 'shutdown failure lost')
    require_effect(result.fetch(:events).none? { |entry| entry.first == :dispatch || (entry.first == :hook && entry.last.fetch('HALT_HOOK') == 'pre-system') }, 'effect after shutdown refusal')
  end
  halt_checks += 1

  check_halt('enabled interrupted same shutdown child') do
    result = observe_halt(classes.fetch('enabled'), name: 'poweroff', args: ['-f', '-m', 'fixture'], interrupt: true)
    require_effect(result.fetch(:failure).is_a?(SystemExit) && result.fetch(:failure).status == 1, 'abort exit changed')
    events = result.fetch(:events)
    pid = events.find { |entry| entry.take(2) == [:fork, :shutdown] }.last
    require_effect(events.select { |entry| entry.take(2) == [:wait, :shutdown] }.map(&:last) == [pid, pid], 'abort did not wait on same child')
    require_effect(events.count { |entry| entry.first == :abort } == 1 && events.count { |entry| entry.first == :abort_marker } == 1, 'abort effects changed')
    require_effect(events.none? { |entry| entry.first == :dispatch || (entry.first == :hook && entry.last.fetch('HALT_HOOK') == 'pre-system') }, 'effect after interrupt')
  end
  halt_checks += 1

  check_halt('enabled no-wall arguments') do
    result = observe_halt(classes.fetch('enabled'), name: 'halt', args: ['-f', '--no-wall', '-m', 'fixture'])
    require_effect(result.fetch(:failure).nil?, 'unexpected failure')
    require_effect(result.fetch(:events).find { |entry| entry.first == :shutdown }.last == %w[osctl shutdown --force --no-wall], 'no-wall arguments changed')
  end
  halt_checks += 1

  [['reboot', [], true], ['reboot', ['--no-kexec'], false], ['halt', ['-r'], false]].each do |name, options, uses_kexec|
    check_halt("disabled loaded kexec #{name} #{options.join(' ')}") do
      result = observe_halt(classes.fetch('disabled'), name: name, args: ['-f', '-m', 'fixture'] + options, loaded: true)
      events = result.fetch(:events)
      require_effect(result.fetch(:failure).nil? && events.last == [:dispatch, '6'], 'reboot dispatch changed')
      require_effect(events.count { |entry| entry.first == :kexec_marker } == (uses_kexec ? 1 : 0), 'kexec marker selection')
      require_effect(events.count { |entry| entry == [:kexec_chmod, 0o100] } == (uses_kexec ? 1 : 0), 'kexec marker mode')
      require_effect(events.none? { |entry| %i[shutdown list abort abort_marker].include?(entry.first) }, 'disabled osctl effect')
      expected_action = uses_kexec ? 'kexec' : 'reboot'
      require_effect(events.find { |entry| entry.first == :hook && entry.last.fetch('HALT_HOOK') == 'pre-system' }.last.fetch('HALT_ACTION') == expected_action, 'final hook action')
    end
    halt_checks += 1
  end

  stage_paths = inputs.fetch('stage3')
  raise 'omitted and enabled stage3 differ' unless File.read(stage_paths.fetch('omitted')) == File.read(stage_paths.fetch('enabled'))
  stage_checks = 0
  Dir.mktmpdir('runit-stage3-effects-') do |private_dir|
    bin = File.join(private_dir, 'bin')
    Dir.mkdir(bin)
    %w[hwclock osctl].each do |command|
      path = File.join(bin, command)
      exit_status = command == 'osctl' ? '$OSCTL_STATUS' : '0'
      File.write(path, "#!#{inputs.fetch('shell')}\nprintf '#{command} %s\\n' \"$*\" >> \"$TRACE_FILE\"\nexit \"#{exit_status}\"\n")
      File.chmod(0o700, path)
    end
    [['omitted', 0], ['enabled', 0], ['disabled', 0], ['enabled', 7]].each_with_index do |(policy, status), index|
      trace = File.join(private_dir, "trace-#{index}")
      File.write(trace, "")
      stdout, stderr, result = Open3.capture3({ 'PATH' => bin, 'TRACE_FILE' => trace, 'OSCTL_STATUS' => status.to_s }, stage_paths.fetch(policy))
      expected = policy == 'disabled' ? ["hwclock -w\n", "hwclock -w\n"] : ["hwclock -w\n", "osctl shutdown --force\n", "hwclock -w\n"]
      raise 'stage3 effects/order changed' unless File.readlines(trace) == expected
      raise 'stage3 output/status changed' unless stdout == "and down we go\n" && stderr.empty? && result.success?
      stage_checks += 1
    end
  end
  puts "halt_checks=#{halt_checks} stage3_checks=#{stage_checks}"
  RUBY
  touch "$out"
''
