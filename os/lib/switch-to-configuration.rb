#!@ruby@/bin/ruby
require 'json'

class Configuration
  OUT = '@out@'
  ETC = '@etc@'
  CURRENT_SYSTEM = '/run/current-system'
  CURRENT_BIN = File.join(CURRENT_SYSTEM, 'sw/bin')
  NEW_BIN = File.join(OUT, 'sw', 'bin')
  INSTALL_BOOTLOADER = '@installBootLoader@'

  class << self
    %i(boot switch test).each do |m|
      define_method(m) { new(dry_run: false).send(m) }
    end
  end

  def self.dry_run
    new(dry_run: true).dry_run
  end

  def initialize(dry_run: true)
    @opts = {dry_run: dry_run}
  end

  def dry_run
    puts 'probing runit services...'
    services = Services.new(opts)

    puts 'probing pools...'
    pools = Pools.new(opts)
    pools.export
    pools.rollback

    if pools.error.any?
      puts "unable to handle pools: #{pools.error.map(&:name).join(',')}"
    end

    puts 'would stop deprecated services...'
    services.stop.each(&:stop)

    puts 'would activate the configuration...'
    activate

    puts 'would reload changed services...'
    services.reload.each(&:reload)

    puts 'would restart changed services...'
    services.restart.each(&:restart)

    puts 'would start new services...'
    services.start.each(&:start)

    activate_osctl(services)
  end

  def boot
    if INSTALL_BOOTLOADER == 'none'
      puts 'no bootloader active'
      return
    end

    system(INSTALL_BOOTLOADER, OUT) || (fail 'unable to install boot loader')
  end

  def switch
    boot
    test
  end

  def test
    puts 'probing runit services...'
    services = Services.new(opts)

    puts 'probing pools...'
    pools = Pools.new(opts)
    pools.export
    pools.rollback

    if pools.error.any?
      puts "unable to handle pools: #{pools.error.map(&:name).join(',')}"
    end

    puts 'stopping deprecated services...'
    services.stop.each(&:stop)

    puts 'activating the configuration...'
    activate

    puts 'reloading changed services...'
    services.reload.each(&:reload)

    puts 'restarting changed services...'
    services.restart.each(&:restart)

    puts 'starting new services...'
    services.start.each(&:wait_for_runit)
    services.start.each(&:start)

    activate_osctl(services)
  end

  def activate
    return if opts[:dry_run]
    system(File.join(OUT, 'activate'))
  end

  protected
  attr_reader :opts

  def activate_osctl(services)
    args = []

    if services.reload.detect { |s| s.name == 'lxcfs' }
      args << '--lxcfs'
    else
      args << '--no-lxcfs'
    end

    if services.restart.detect { |s| s.name == 'osctld' }
      # osctld has been restarted, so system files are already regenerated
      # and we just have to refresh LXCFS
      args << '--no-system'

      # It takes time for osctld to start
      wait_for_osctld

    else
      args << '--system'
    end

    puts "> osctl activate #{args.join(' ')}"
    return if opts[:dry_run]

    system(File.join(CURRENT_BIN, 'osctl'), 'activate', *args)
  end

  def wait_for_osctld
    if opts[:dry_run]
      puts 'would wait for osctld to start...'
      return
    end

    puts 'waiting for osctld to start...'
    system(File.join(CURRENT_BIN, 'osctl'), 'ping', '0')
  end
end

class Services
  RELOADABLE = %w(lxcfs)
  Service = Struct.new(:name, :base_path, :service_path, :opts) do
    attr_reader :run_path

    def initialize(*_)
      super

      @run_path = File.realpath(File.join(base_path, service_path, 'run'))
    end

    def ==(other)
      run_path == other.run_path
    end

    %i(start stop restart).each do |m|
      define_method(m) do
        puts "> sv #{m} #{name}"

        unless opts[:dry_run]
          system(File.join(Configuration::CURRENT_BIN, 'sv'), m.to_s, name)
        end
      end
    end

    def reload
      m = reload_method
      puts "> sv #{m} #{name}"

      unless opts[:dry_run]
        system(File.join(Configuration::CURRENT_BIN, 'sv'), m, name)
      end
    end

    def reload_method
      case name
      when 'lxcfs'
        '1'
      else
        'reload'
      end
    end

    # Wait until runit registers the service
    def wait_for_runit
      # This method is called after activation, so we use / instead
      # of the original base_path.
      check = File.join('/', service_path, 'supervise', 'ok')

      100.times do
        return if File.exist?(check)
        sleep(0.2)
      end

      fail "service #{name} not registered by runit"
    end
  end

  def initialize(dry_run: true)
    @opts = {dry_run: dry_run}
    @old_services = read(
      File.join(Configuration::CURRENT_SYSTEM, '/services'),
      '/',
    )
    @new_services = read(
      File.join(Configuration::OUT, '/services'),
      Configuration::ETC,
    )
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
      old_services[s] != new_services[s] && !RELOADABLE.include?(s)
    end.map { |s| new_services[s] }
  end

  # Services that have been changed and should be reloaded
  # @return [Array<Service>]
  def reload
    (old_services.keys & new_services.keys).select do |s|
      old_services[s] != new_services[s] && RELOADABLE.include?(s)
    end.map { |s| new_services[s] }
  end

  protected
  attr_reader :old_services, :new_services, :opts

  # Read service directory
  # @param list [String] Path to service list
  # @param base_dir [String] absolute path to a directory containing the system's
  #                          `/etc`
  # @return [Hash<String, Service>]
  def read(list, base_dir)
    ret = {}

    JSON.parse(File.read(list)).each do |name, service|
      begin
        ret[name] = Service.new(
          name,
          base_dir,
          File.join(service['directory'], name),
          opts,
        )

      rescue Errno::ENOENT
        warn "service '#{name}' not found at "+
             "'#{File.join(base_dir, service['directory'])}'"
        next
      end
    end

    ret
  end
end

class Pools
  Pool = Struct.new(:name, :state, :rollback_version)

  attr_reader :uptodate, :to_upgrade, :to_rollback, :error

  def initialize(dry_run: true)
    @opts = {dry_run: dry_run}

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
        fail "rollback of pool #{pool.name} failed, cannot proceed"
      end
    end
  end

  # Export pools from osctld before upgrade
  #
  # This will stop all containers from outdated pools. We're counting on the
  # fact that if there are new migrations, then osctld has to have changed
  # as well, so it is restarted by {Services}. After restart, osctld will run
  # `osup upgrade` on all imported pools.
  def export
    (to_rollback + to_upgrade).each do |pool|
      puts "> exporting pool #{pool.name} to upgrade"
      next if opts[:dry_run]

      # TODO: do not fail if the pool is not imported
      ret = system(
        File.join(Configuration::CURRENT_BIN, 'osctl'),
        'pool', 'export', '-f', pool.name
      )

      unless ret
        fail "export of pool #{pool.name} failed, cannot proceed"
      end
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

  def check(swbin)
    ret = {}

    IO.popen("#{File.join(swbin, 'osup')} check") do |io|
      io.each_line do |line|
        name, state, version = line.strip.split
        ret[name] = Pool.new(name, state.to_sym, version)
      end
    end

    ret

  rescue Errno::ENOENT
    # osup isn't available in the to-be-replaced OS version
    {}
  end
end

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
  warn "Usage: #{$0} switch|dry-activate"
  exit(false)
end
