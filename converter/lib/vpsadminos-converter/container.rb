module VpsAdminOS::Converter
  class Container
    attr_accessor :id, :user, :group, :dataset, :distribution, :version,
      :hostname, :nesting
    attr_reader :dns_resolvers, :netifs, :cgparams, :autostart

    def initialize(id, user, group)
      @id = id
      @user = user
      @group = group
      @distribution = 'unknown'
      @hostname = 'ct'
      @nesting = false
      @dns_resolvers = []
      @netifs = []
      @cgparams = CGParams.new
      @autostart = AutoStart.new
    end

    def dump_config
      {
        'user' => user.name,
        'group' => group.name,
        'distribution' => distribution,
        'version' => version,
        'net_interfaces' => netifs.map(&:dump),
        'cgparams' => cgparams.dump,
        'prlimits' => [], # TODO
        'mounts' => [], # TODO
        'autostart' => autostart.dump,
        'hostname' => hostname,
        'dns_resolvers' => dns_resolvers,
        'nesting' => nesting,
      }
    end
  end
end
