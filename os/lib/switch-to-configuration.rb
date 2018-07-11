#!@ruby@/bin/ruby

class Configuration
  OUT = '@out@'
  ETC = '@etc@'
  SERVICE_DIR = '/etc/service'
  BIN = '/run/current-system/sw/bin'

  def self.switch
    new.switch
  end

  def switch
    puts 'probing runit services...'
    services = Services.new

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
    system(File.join(OUT, 'activate'))
  end
end

class Services
  RELOADABLE = %w(lxcfs)
  Service = Struct.new(:name, :path) do
    def ==(other)
      path == other.path
    end

    %i(start stop restart).each do |m|
      define_method(m) do
        puts "> sv #{m} #{name}"
        system(File.join(Configuration::BIN, 'sv'), m.to_s, name)
      end
    end

    def reload
      m = reload_method

      puts "> sv #{m} #{name}"
      system(File.join(Configuration::BIN, 'sv'), m, name)
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

  def initialize
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
  attr_reader :old_services, :new_services

  # Read service directory
  # @return [Hash<String, Service>]
  def read(dir)
    ret = {}

    Dir.entries(dir).each do |f|
      next if %w(. ..).include?(f)

      path = File.join(dir, f)
      next unless Dir.exist?(path)

      ret[f] = Service.new(f, File.realpath(File.join(path, 'run')))
    end

    ret
  end
end

Configuration.switch
