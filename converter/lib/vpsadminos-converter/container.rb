module VpsAdminOS::Converter
  class Container
    attr_accessor :id, :user, :group, :dataset, :distribution, :version,
      :hostname, :nesting
    attr_reader :dns_resolvers

    def initialize(id, user, group)
      @id = id
      @user = user
      @group = group
      @distribution = 'unknown'
      @hostname = 'ct'
      @nesting = false
      @dns_resolvers = []
    end

    def dump_config
      {
        'user' => user.name,
        'group' => group.name,
        'distribution' => distribution,
        'version' => version,
        'net_interfaces' => [], # TODO
        'cgparams' => [], # TODO
        'prlimits' => [], # TODO
        'mounts' => [], # TODO
        'hostname' => hostname,
        'dns_resolvers' => dns_resolvers,
        'nesting' => nesting,
      }
    end
  end
end
