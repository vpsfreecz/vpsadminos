#!@ruby@/bin/ruby

class Configuration
  OUT = '@out@'
  ETC = '@etc@'
  SERVICE_DIR = '/etc/service'
  BIN = '/run/current-system/sw/bin'

  def self.switch
    new(dry_run: false).switch
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
  end

  def switch
    puts 'probing runit services...'
    services = Services.new(opts)

    puts 'stopping deprecated services...'
    services.stop.each(&:stop)

    puts 'activating the configuration...'
    activate

    puts 'reloading changed services...'
    services.reload.each(&:reload)

    puts 'restarting changed services...'
    services.restart.each(&:restart)

    puts 'starting new services...'
    services.start.each(&:start)
  end

  def activate
    return if opts[:dry_run]
    system(File.join(OUT, 'activate'))
  end

  protected
  attr_reader :opts
end

class Services
  RELOADABLE = %w(lxcfs)
  Service = Struct.new(:name, :path, :opts) do
    def ==(other)
      path == other.path
    end

    %i(start stop restart).each do |m|
      define_method(m) do
        puts "> sv #{m} #{name}"

        unless opts[:dry_run]
          system(File.join(Configuration::BIN, 'sv'), m.to_s, name)
        end
      end
    end

    def reload
      m = reload_method
      puts "> sv #{m} #{name}"

      unless opts[:dry_run]
        system(File.join(Configuration::BIN, 'sv'), m, name)
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
  end

  def initialize(dry_run: true)
    @opts = {dry_run: dry_run}
    @old_services = read(Configuration::SERVICE_DIR)
    @new_services = read(File.join(Configuration::ETC, Configuration::SERVICE_DIR))
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
  # @return [Hash<String, Service>]
  def read(dir)
    ret = {}

    Dir.entries(dir).each do |f|
      next if %w(. ..).include?(f)

      path = File.join(dir, f)
      next unless Dir.exist?(path)

      ret[f] = Service.new(f, File.realpath(File.join(path, 'run')), opts)
    end

    ret
  end
end

case ARGV[0]
when 'switch', 'boot', 'test'
  Configuration.switch

when 'dry-activate'
  Configuration.dry_run

else
  warn "Usage: #{$0} switch|dry-activate"
  exit(false)
end
