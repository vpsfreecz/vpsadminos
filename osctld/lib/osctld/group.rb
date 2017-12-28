module OsCtld
  class Group
    include Lockable

    Param = Struct.new(:subsystem, :name, :value) do
      # Load from config
      def self.load(hash)
        new(hash['subsystem'], hash['name'], hash['value'])
      end

      # Load from client
      def self.import(hash)
        new(hash[:subsystem], hash[:parameter], hash[:value])
      end

      # Dump to config
      def dump
        Hash[to_h.map { |k,v| [k.to_s, v] }]
      end

      # Export to client
      def export
        {
          subsystem: subsystem,
          parameter: name,
          value: value,
        }
      end
    end

    attr_reader :name, :path, :params

    def initialize(name, load: true, root: false)
      init_lock
      @name = name
      @root = root
      @params = []
      load_config if load
    end

    def id
      @name
    end

    def root?
      @root
    end

    def configure(path, params = [])
      @path = path
      set(params, save: false)
      save_config
    end

    # Process params from the client and return internal representation.
    # Invalid parameters raise an exception.
    def import_params(params)
      params.map do |hash|
        p = Param.import(hash)

        # Check if the subsystem is valid
        subsys = real_subsystem(p.subsystem)
        path = File.join(OsCtld::CGROUP_FS, subsys)

        unless Dir.exist?(path)
          raise CGroupSubsystemNotFound,
            "CGroup subsystem '#{p.subsystem}' not found at '#{path}'"
        end

        # Check parameter
        param = File.join(path, p.name)

        unless File.exist?(param)
          raise CGroupParameterNotFound, "CGroup parameter '#{param}' not found"
        end

        p
      end
    end

    def set(new_params, save: true)
      exclusively do
        new_params.each do |new_p|
          replaced = false

          params.map! do |p|
            if p.subsystem == new_p.subsystem && p.name == new_p.name
              replaced = true
              new_p

            else
              p
            end
          end

          next if replaced

          params << new_p
        end
      end

      save_config if save
    end

    def unset(del_params, save: true)
      exclusively do
        del_params.each do |del_h|
          del_p = Param.import(del_h)

          params.delete_if do |p|
            p.subsystem == del_p.subsystem && p.name == del_p.name
          end
        end
      end

      save_config if save
    end

    def config_path
      File.join('/', OsCtld::CONF_DS, 'group', "#{id}.yml")
    end

    def lxc_home(user)
      user.lxc_home(self)
    end

    def cgroup_path
      if root?
        path

      else
        File.join(GroupList.root.path, path)
      end
    end

    def full_cgroup_path(user)
      File.join(cgroup_path, user.name)
    end

    def abs_cgroup_path(subsystem)
      File.join(OsCtld::CGROUP_FS, real_subsystem(subsystem), cgroup_path)
    end

    def setup_for?(user)
      Dir.exist?(lxc_home(user))
    end

    def has_containers?
      ct = ContainerList.get.detect { |ct| ct.group.name == name }
      ct ? true : false
    end

    def containers
      ret = []

      ContainerList.get.each do |ct|
        next if ct.group != self || ret.include?(ct)
        ret << ct
      end

      ret
    end

    def users
      ret = []

      ContainerList.get.each do |ct|
        next if ct.group != self || ret.include?(ct.user)
        ret << ct.user
      end

      ret
    end

    protected
    def load_config
      cfg = YAML.load_file(config_path)

      @path = cfg['path']
      @params = (cfg['params'] || []).map { |v| Param.load(v) }
    end

    def save_config
      File.open(config_path, 'w', 0400) do |f|
        f.write(YAML.dump({
          'path' => path,
          'params' => params.map(&:dump),
        }))
      end

      File.chown(0, 0, config_path)
    end

    def real_subsystem(subsys)
      return 'cpu,cpuacct' if %w(cpu cpuacct).include?(subsys)
      # TODO: net_cls, net_prio?
      subsys
    end
  end
end
