module VpsAdminOS::Converter
  class Container
    attr_accessor :id, :user, :group, :dataset, :rootfs, :distribution, :version,
      :arch, :hostname, :nesting
    attr_reader :dns_resolvers, :netifs, :cgparams, :devices, :autostart

    def initialize(id, user, group)
      @id = id
      @user = user
      @group = group
      @distribution = 'unknown'
      @arch = `uname -m`.strip
      @hostname = 'ct'
      @nesting = false
      @dns_resolvers = []
      @netifs = []
      @cgparams = CGParams.new
      @devices = Devices.new
      @autostart = AutoStart.new
    end

    def datasets
      return @datasets if @datasets

      @datasets = [dataset] + dataset.descendants
    end

    def dump_config
      {
        'user' => user.name,
        'group' => group.name,
        'distribution' => distribution,
        'version' => version,
        'arch' => arch,
        'net_interfaces' => netifs.map(&:dump),
        'cgparams' => cgparams.dump,
        'devices' => devices.dump,
        'prlimits' => [], # TODO
        'mounts' => [], # TODO
        'autostart' => autostart.dump,
        'hostname' => hostname,
        'dns_resolvers' => dns_resolvers.empty? ? nil : dns_resolvers,
        'nesting' => nesting,
      }
    end
  end
end
