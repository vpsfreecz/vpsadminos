require 'svctl/version'
require 'svctl/service'

module SvCtl
  # Directory with runlevels
  RUNSVDIR = '/etc/runit/runsvdir'

  # Directory with available services
  SERVICE_DIR = '/etc/runit/services'

  # List all available services
  # @return [Array<Service>]
  def self.all_services
    svdir = File.join(SERVICE_DIR)
    ret = []

    Dir.entries(svdir).each do |v|
      next if %w(. ..).include?(v)

      ret << Service.new(v, nil)
    end

    ret
  end

  # List seervices from selected runlevel
  # @param runlevel [String]
  # @return [Array<Service>]
  def self.runlevel_services(runlevel = 'current')
    svdir = File.join(RUNSVDIR, runlevel)
    ret = []

    Dir.entries(svdir).each do |v|
      next if %w(. ..).include?(v)

      ret << Service.new(v, runlevel)
    end

    ret
  end

  # Enable service in selected runlevel
  # @param service [String]
  # @param runlevel [String]
  def self.enable(service, runlevel = 'current')
    sv = Service.new(service, runlevel)
    fail 'service not found' unless sv.exist?

    sv.enable
  end

  # Disable service from selected runlevel
  # @param service [String]
  # @param runlevel [String]
  def self.disable(service, runlevel = 'current')
    sv = Service.new(service, runlevel)
    fail 'service not found' unless sv.exist?

    sv.disable if sv.enabled?
  end

  # List all runlevels
  # @return [Array<String>]
  def self.runlevels
    ret = []

    Dir.entries(RUNSVDIR).each do |v|
      next if %w(. .. current previous).include?(v)
      next unless Dir.exist?(File.join(RUNSVDIR, v))

      ret << v
    end

    ret
  end

  # @return [String] current runlevel
  def self.runlevel
    File.basename(File.readlink(File.join(RUNSVDIR, 'current')))
  end

  # Switch to new runlevel
  # @param runlevel [String]
  def self.switch(runlevel)
    system('runsvchdir', runlevel)
  end
end
