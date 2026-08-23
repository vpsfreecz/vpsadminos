#!@ruby@/bin/ruby
require 'fileutils'
require 'json'
require 'open3'

class Configuration
  OUT = '@out@'.freeze
  ETC = File.join(OUT, 'etc')
  CURRENT_SYSTEM = '/run/current-system'.freeze
  CURRENT_BIN = File.join(CURRENT_SYSTEM, 'sw/bin')
  NEW_BIN = File.join(OUT, 'sw', 'bin')
  INSTALL_BOOTLOADER = '@installBootLoader@'.freeze

  class << self
    %i[boot switch test].each do |m|
      define_method(m) { new(dry_run: false).send(m) }
    end
  end

  def self.dry_run
    new(dry_run: true).dry_run
  end

  def initialize(dry_run: true)
    @opts = { dry_run: }
  end

  def dry_run
    puts 'probing runit services...'
    services = Services.new(**opts)

    puts 'probing pools...'
    pools = Pools.new(**opts)
    pools.export
    pools.rollback

    if pools.error.any?
      puts "unable to handle pools: #{pools.error.map(&:name).join(',')}"
    end

    osctld = OsctldRestart.new(services, dry_run: true)
    osctld.prepare

    puts 'would stop deprecated services...'
    services.stop.each(&:stop)

    puts 'would stop changed services...'
    services.restart_before_osctld.each(&:stop)

    puts 'would activate the configuration...'
    activate

    services.switch_runlevel

    osctld_start_config(services)

    osctld.start_and_wait

    puts 'would reload changed services...'
    services.reload.each(&:reload)

    puts 'would restart changed services...'
    services.deferred_restart_after_osctld.each(&:stop)
    services.restart_after_osctld.each(&:start)

    puts 'runit would start new services...'
    services.start.each(&:start)

    activate_osctl(services)
  end

  def boot
    if INSTALL_BOOTLOADER == 'none'
      puts 'no bootloader active'
      return
    end

    system(INSTALL_BOOTLOADER, OUT) || (raise 'unable to install boot loader')
  end

  def switch
    boot
    test
  end

  def test
    puts 'probing runit services...'
    services = Services.new(**opts)

    puts 'probing pools...'
    pools = Pools.new(**opts)
    pools.export
    pools.rollback

    if pools.error.any?
      puts "unable to handle pools: #{pools.error.map(&:name).join(',')}"
    end

    osctld = OsctldRestart.new(services, dry_run: false)
    osctld.prepare

    puts 'stopping deprecated services...'
    services.stop.each(&:stop)

    puts 'stopping changed services...'
    services.restart_before_osctld.each(&:stop)

    puts 'activating the configuration...'
    activate

    services.switch_runlevel

    osctld_start_config(services)

    osctld.start_and_wait

    puts 'reloading changed services...'
    services.reload.each(&:reload)

    puts 'restarting changed services...'
    services.deferred_restart_after_osctld.each(&:stop)
    services.restart_after_osctld.each(&:start)

    puts 'runit will start new services...'

    activate_osctl(services)
  end

  def activate
    return if opts[:dry_run]

    system(File.join(OUT, 'activate'))
  end

  protected

  attr_reader :opts

  def osctld_start_config(services)
    return unless services.restart.detect { |s| s.name == 'osctld' && !s.skip? }

    cfg = {}

    puts '> osctld start config:'

    if cfg.empty?
      puts '- no changes'
      return
    end

    return if opts[:dry_run]

    puts '- writing config'

    dir = '/run/osctl/configs/osctld'
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'start-config.json'), cfg.to_json)
  end

  def activate_osctl(services)
    # If osctld is restarted, it will regenerate system files by itself
    return if services.restart.detect { |s| s.name == 'osctld' && !s.skip? }

    args = ['--system']

    puts "> osctl activate #{args.join(' ')}"
    return if opts[:dry_run]

    system(File.join(CURRENT_BIN, 'osctl'), 'activate', *args)
  end
end

class OsctldRestart
  SERVICE_STOP_TIMEOUT = 60
  READY_TIMEOUT = 300

  def initialize(
    services,
    dry_run:,
    service_stop_timeout: SERVICE_STOP_TIMEOUT,
    ready_timeout: READY_TIMEOUT
  )
    @service = services.osctld_restart
    @target_service = services.osctld_target
    @dry_run = dry_run
    @service_stop_timeout = service_stop_timeout
    @ready_timeout = ready_timeout
  end

  def prepare
    return unless service

    if dry_run
      puts '> osctl daemon prepare-stop'
      puts "> sv stop osctld; wait up to #{service_stop_timeout} seconds"
      return
    end

    status = osctl_json('daemon', 'status')
    unless status['initialized']
      raise 'osctld is not initialized, refusing runtime replacement'
    end
    if status['legacy'] == true
      raise 'running osctld requires the legacy runtime upgrade protocol'
    end

    unless run_osctl('daemon', 'prepare-stop')
      run_osctl('daemon', 'resume')
      raise 'osctld lifecycle drain failed before activation'
    end

    service.stop
    return if wait_service_down

    service.start
    run_osctl('daemon', 'resume')
    raise "osctld supervisor did not stop within #{service_stop_timeout} seconds"
  end

  def start_and_wait
    return unless service

    if dry_run
      puts '> sv start osctld'
      puts "> osctl daemon wait-ready --timeout #{ready_timeout}"
      return
    end

    target_service.start
    return if wait_for_target_ready

    raise "target osctld did not become ready within #{ready_timeout} seconds"
  end

  protected

  attr_reader :service, :target_service, :service_stop_timeout, :ready_timeout,
              :dry_run

  def wait_service_down
    deadline = monotonic_now + service_stop_timeout

    loop do
      return true unless service.running?
      return false if monotonic_now >= deadline

      sleep(0.2)
    end
  end

  def wait_for_target_ready
    deadline = monotonic_now + ready_timeout

    loop do
      remaining = deadline - monotonic_now
      return false if remaining <= 0
      return true if run_osctl(
        'daemon',
        'wait-ready',
        '--timeout',
        remaining.ceil.to_s
      )

      sleep([0.2, remaining].min)
    end
  end

  def osctl_json(*args)
    output, error, status = Open3.capture3(
      File.join(Configuration::NEW_BIN, 'osctl'),
      '--json',
      *args
    )
    raise "osctl #{args.join(' ')} failed: #{error.strip}" unless status.success?

    JSON.parse(output)
  rescue JSON::ParserError => e
    raise "osctl #{args.join(' ')} returned invalid JSON: #{e.message}"
  end

  def run_osctl(*args)
    puts "> osctl #{args.join(' ')}"
    system(File.join(Configuration::NEW_BIN, 'osctl'), *args)
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

class Services
  class ServiceNameList
    def initialize(path)
      @services = parse(path)
    end

    def include?(name)
      @services.any? { |v| File.fnmatch?(v, name) }
    end

    protected

    def parse(path)
      ret = []

      File.open(path) do |f|
        f.each_line { |line| ret << line.strip }
      end

      ret
    rescue Errno::ENOENT
      []
    end
  end

  Service = Struct.new(:name, :etc_path, :cfg, :opts) do
    attr_reader :run_path, :on_change, :reload_method, :restart_triggers

    def initialize(*_)
      super
      @run_path = File.realpath(File.join(etc_path, 'runit/services', name, 'run'))
      @on_change = cfg['onChange'].to_sym
      @reload_method = cfg['reloadMethod']
      @restart_triggers = cfg.fetch('restartTriggers', [])
    end

    def ==(other)
      run_path == other.run_path && restart_triggers == other.restart_triggers
    end

    def restart_triggers_changed?(other)
      restart_triggers != other.restart_triggers
    end

    %i[start stop restart].each do |m|
      define_method(m) do
        if opts[:skip]
          puts "> skip service #{name}"
          next
        end

        puts "> sv #{m} #{name}"

        return if opts[:dry_run]

        system(File.join(Configuration::CURRENT_BIN, 'sv'), m.to_s, name)
      end
    end

    def reload
      if opts[:skip]
        puts "> skip service #{name}"
        return
      end

      puts "> sv #{reload_method} #{name}"

      return if opts[:dry_run]

      system(File.join(Configuration::CURRENT_BIN, 'sv'), reload_method, name)
    end

    def skip
      puts "> skipping #{name}"
    end

    def skip?
      opts[:skip]
    end

    def running?
      pid = File.read(File.join('/run/service', name, 'supervise/pid')).to_i
      return false if pid <= 0

      Process.kill(0, pid)
      true
    rescue Errno::ENOENT, Errno::ESRCH
      false
    end
  end

  def initialize(dry_run: true)
    @opts = { dry_run: }

    @old_cfg = read_cfg(File.join(Configuration::CURRENT_SYSTEM, '/services'))
    @new_cfg = read_cfg(File.join(Configuration::OUT, '/services'))

    @old_runlevel = File.basename(File.realpath('/service'))
    @new_runlevel = get_runlevel(@new_cfg, @old_runlevel)

    @protected_list = ServiceNameList.new('/run/runit/protected-services.txt')

    @old_services = get_services(@old_cfg, @old_runlevel, '/etc')
    @new_services = get_services(@new_cfg, @new_runlevel, Configuration::ETC)
  end

  # Services that are new and should be started
  # @return [Array<Service>]
  def start
    (new_services.keys - old_services.keys).map { |s| new_services[s] }
  end

  # Services that have been removed and should be stopped
  # @return [Array<Service>]
  def stop
    (old_services.keys - new_services.keys).map { |s| old_services[s] }
  end

  # Services that have been changed and should be restarted
  # @return [Array<Service>]
  def restart
    (old_services.keys & new_services.keys).select do |s|
      old_service = old_services[s]
      new_service = new_services[s]

      new_service.restart_triggers_changed?(old_service) \
        || (old_service != new_service && new_service.on_change == :restart)
    end.map { |s| new_services[s] }
  end

  def osctld_restart
    restart.detect { |service| service.name == 'osctld' && !service.skip? }
  end

  def osctld_target
    service = new_services['osctld']
    service unless service&.skip?
  end

  def restart_before_osctld
    restart.reject do |service|
      (service.name == 'osctld' && !service.skip?) \
        || service == deferred_nodectld_restart
    end
  end

  def deferred_restart_after_osctld
    [deferred_nodectld_restart].compact
  end

  def restart_after_osctld
    restart.reject { |service| service.name == 'osctld' && !service.skip? }
  end

  # Services that have been changed and should be reloaded
  # @return [Array<Service>]
  def reload
    services = (old_services.keys & new_services.keys).select do |s|
      old_service = old_services[s]
      new_service = new_services[s]

      !new_service.restart_triggers_changed?(old_service) \
        && old_service != new_service \
        && new_service.on_change == :reload
    end.map { |s| new_services[s] }

    kernel_modules, other = services.partition { |svc| svc.name == 'kernel-modules' }
    kernel_modules + other
  end

  def switch_runlevel
    return if old_runlevel == new_runlevel

    if opts[:dry_run]
      puts 'would switch runlevel...'
    else
      puts 'switching runlevel...'
    end

    puts "> runsvchdir #{new_runlevel}"
    return if opts[:dry_run]

    system(File.join(Configuration::CURRENT_BIN, 'runsvchdir'), new_runlevel)
  end

  protected

  attr_reader :old_cfg, :new_cfg, :protected_list, :old_services, :new_services, :old_runlevel, :new_runlevel, :opts

  def nodectld_restart
    restart.detect { |service| service.name == 'nodectld' && !service.skip? }
  end

  def deferred_nodectld_restart
    osctld_restart && nodectld_restart
  end

  # Parse service config
  # @param path [String]
  # @return [Hash]
  def read_cfg(path)
    JSON.parse(File.read(path))
  end

  # Return services from a selected runlevel
  # @param cfg [Hash] service config
  # @param runlevel [String] include only services from this runlevel
  # @param etc_dir [String] absolute path to a directory containing the system's
  #                          `/etc`
  # @return [Hash<String, Service>]
  def get_services(cfg, runlevel, etc_dir)
    ret = {}

    cfg['services'].each do |name, service|
      next unless service['runlevels'].include?(runlevel)

      begin
        ret[name] = Service.new(
          name,
          etc_dir,
          service,
          opts.merge({ skip: protected_list.include?(name) })
        )
      rescue Errno::ENOENT
        warn "service '#{name}' not found"
        next
      end
    end

    ret
  end

  # Return target runlevel
  def get_runlevel(cfg, old_runlevel)
    if cfg['defaultRunlevel'] == old_runlevel \
        || cfg['services'].map { |_k, v| v['runlevels'] }.flatten.include?(old_runlevel)
      old_runlevel

    else
      cfg['defaultRunlevel']
    end
  end
end

class PoolFlags
  KNOWN_FLAGS = %w[export stop].freeze

  def initialize(string_flags)
    @flags = {}

    KNOWN_FLAGS.each do |flag|
      @flags[flag] = false
    end

    if string_flags.nil?
      set_default_flags
      return
    end

    string_flags.split(',').each do |flag|
      next if flag == '-'

      unless KNOWN_FLAGS.include?(flag)
        warn "unknown pool flag '#{flag}', using safe defaults"
        set_default_flags
        break
      end

      @flags[flag] = true
    end
  end

  KNOWN_FLAGS.each do |flag|
    define_method(:"flag_#{flag}?") { @flags[flag] }
  end

  def export_pool?
    @flags['export']
  end

  def stop_containers?
    @flags['stop']
  end

  protected

  def set_default_flags
    @flags.update({
      'export' => true,
      'stop' => true
    })
  end
end

class Pools
  Pool = Struct.new(:name, :state, :rollback_version, :flags)

  attr_reader :uptodate, :to_upgrade, :to_rollback, :error

  def initialize(dry_run: true)
    @opts = { dry_run: }

    @uptodate = []
    @to_upgrade = []
    @to_rollback = []
    @error = []

    @old_pools = check(Configuration::CURRENT_BIN)
    @new_pools = check(Configuration::NEW_BIN)

    resolve
  end

  # Rollback pools using the current OS version, as the activated OS version
  # is older
  def rollback
    to_rollback.each do |pool|
      puts "> rolling back pool #{pool.name}"
      next if opts[:dry_run]

      ret = system(
        File.join(Configuration::CURRENT_BIN, 'osup'),
        'rollback', pool.name, pool.rollback_version
      )

      unless ret
        raise "rollback of pool #{pool.name} failed, cannot proceed"
      end
    end
  end

  # Export pools from osctld before upgrade
  #
  # Depending on `osup check`, this will stop all containers from outdated pools.
  # We're counting on the fact that if there are new migrations, then osctld has
  # to have changed as well, so it is restarted by {Services}. After restart,
  # osctld will run `osup upgrade` on all imported pools.
  def export
    to_rollback.each do |pool|
      check_rollback = `#{File.join(Configuration::CURRENT_BIN, 'osup')} check-rollback "#{pool.name}" "#{pool.rollback_version}"`
      rollback_flags = PoolFlags.new($?.exitstatus == 0 ? check_rollback.strip : nil)

      export_pool(pool, rollback_flags, 'rollback')
    end

    to_upgrade.each do |pool|
      export_pool(pool, pool.flags, 'upgrade')
    end
  end

  protected

  attr_reader :opts, :old_pools, :new_pools

  def resolve
    new_pools.each do |name, pool|
      case pool.state
      when :ok
        uptodate << pool

      when :outdated
        to_upgrade << pool

      when :incompatible
        if old_pools[name] && old_pools[name].state == :ok
          to_rollback << pool

        else
          error << pool
        end
      end
    end
  end

  def export_pool(pool, flags, action)
    unless flags.export_pool?
      puts "> pool #{pool.name} is ready for #{action}"
      return
    end

    if flags.stop_containers?
      puts "> stopping containers and exporting pool #{pool.name} to #{action}"
    else
      puts "> exporting pool #{pool.name} to #{action}, not stopping containers"
    end

    return if opts[:dry_run]

    # TODO: do not fail if the pool is not imported

    cmd = [
      File.join(Configuration::CURRENT_BIN, 'osctl'),
      'pool',
      'export',
      '-f'
    ]

    cmd << if flags.stop_containers?
             '--stop-containers'
           else
             '--no-stop-containers'
           end

    cmd << pool.name

    ret = system(*cmd)

    return if ret

    raise "export of pool #{pool.name} failed, cannot proceed"
  end

  def check(swbin)
    ret = {}

    IO.popen("#{File.join(swbin, 'osup')} check") do |io|
      io.each_line do |line|
        name, state, version, flags = line.strip.split
        ret[name] = Pool.new(name, state.to_sym, version, PoolFlags.new(flags))
      end
    end

    ret
  rescue Errno::ENOENT
    # osup isn't available in the to-be-replaced OS version
    {}
  end
end

if __FILE__ == $0
  case ARGV[0]
  when 'boot'
    Configuration.boot
  when 'switch'
    Configuration.switch
  when 'test'
    Configuration.test
  when 'dry-activate'
    Configuration.dry_run
  else
    warn "Usage: #{$0} switch|boot|test|dry-activate"
    exit(false)
  end
end
