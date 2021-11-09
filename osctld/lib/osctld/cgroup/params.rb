require 'libosctl'
require 'osctld/lockable'

module OsCtld
  class CGroup::Params
    include Lockable
    include OsCtl::Lib::Utils::Log

    # Load CGroup parameters from config
    def self.load(owner, cfg)
      new(owner, params: (cfg || []).map { |v| CGroup::Param.load(v) })
    end

    # @param owner [Group, Container]
    # @param params [Array<CGroup::Param>]
    def initialize(owner, params: [])
      init_lock
      @owner = owner
      @params = params
    end

    # Process params from the client and return internal representation.
    # Invalid parameters raise an exception.
    def import(new_params)
      new_params.map do |hash|
        p = CGroup::Param.import(hash)

        # Check if the subsystem is valid
        subsys = CGroup.real_subsystem(p.subsystem)
        path = File.join(CGroup::FS, subsys)

        unless Dir.exist?(path)
          raise CGroupSubsystemNotFound,
            "CGroup subsystem '#{p.subsystem}' not found at '#{path}'"
        end

        # Check parameter
        param = File.join(path, 'osctl', p.name)

        unless File.exist?(param)
          raise CGroupParameterNotFound, "CGroup parameter '#{param}' not found"
        end

        p
      end
    end

    def set(new_params, append: false, save: true)
      exclusively do
        new_params.each do |new_p|
          replaced = false

          params.map! do |p|
            if p.subsystem == new_p.subsystem && p.name == new_p.name
              replaced = true

              new_p.value = p.value + new_p.value if append
              new_p

            else
              p
            end
          end

          next if replaced

          params << new_p
        end
      end

      owner.save_config if save
    end

    # @param save [Boolean] save config file
    # @param reset [Boolean] reset cgroup parameter value
    # @param keep_going [Boolean] skip parameters that do not exist
    # @yieldparam subsystem [String] cgroup subsystem
    # @yieldreturn [String] absolute path to the cgroup directory
    def unset(del_params, save: true, reset: true, keep_going: false, &block)
      exclusively do
        del_params.each do |del_h|
          del_p = CGroup::Param.import(del_h)

          params.delete_if do |p|
            del = p.subsystem == del_p.subsystem && p.name == del_p.name
            next(del) if !del || !reset
            reset(p, keep_going, &block)
            true
          end
        end
      end

      owner.save_config if save
    end

    def each(&block)
      params.each(&block)
    end

    def detect(&block)
      params.detect(&block)
    end

    # Apply configured cgroup parameters into the system
    # @param keep_going [Boolean] skip parameters that do not exist
    # @yieldparam subsystem [String] cgroup subsystem
    # @yieldreturn [String] absolute path to the cgroup directory
    def apply(keep_going: false, &block)
      failed = apply_params(params, keep_going: keep_going, &block).select do |p|
        p.name.start_with?('memory.')
      end

      apply_params(failed, keep_going: keep_going, &block) if failed.any?
    end

    # Replace all parameters by a new list of parameters
    # @param new_params [Array<CGroup::Param>]
    # @param save [Boolean] update the owner's config file
    def replace(new_params, save: true, &block)
      @params.each do |p|
        found = new_params.detect do |n|
          n.subsystem == p.subsystem && n.name == p.name
        end

        reset(p, true, &block) unless found
      end

      @params = new_params
      owner.save_config if save
    end

    # Reset cgroup parameter to its initial/unlimited value.
    #
    # Only a limited subset of cgroup parameters is supported.
    #
    # @param param [CGroup::Param]
    # @param keep_going [Boolean]
    # @yieldparam subsystem [String] cgroup subsystem
    # @yieldreturn [String] absolute path to the cgroup directory
    def reset(param, keep_going)
      v = reset_value(param)
      return unless v

      path = File.join(yield(param.subsystem), param.name)
      CGroup.set_param(path, v)

    rescue CGroupFileNotFound
      raise unless keep_going
      log(
        :info,
        :cgroup,
        "Skip #{path}, group or parameter does not exist"
      )
    end

    # Dump params to config
    def dump
      params.select(&:persistent).map(&:dump)
    end

    def dup(new_owner)
      ret = super()
      ret.init_lock
      ret.instance_variable_set('@owner', new_owner)
      ret.instance_variable_set('@params', params.map(&:clone))
      ret
    end

    protected
    attr_reader :owner, :params

    # @param param_list [Array<CGroup::Param>]
    # @param keep_going [Boolean]
    # @return [Array<CGroup::Param>] parameters that failed to set
    def apply_params(param_list, keep_going: false)
      failed = []

      param_list.each do |p|
        path = File.join(yield(p.subsystem), p.name)

        begin
          failed << p unless CGroup.set_param(path, p.value)

        rescue CGroupFileNotFound
          raise unless keep_going

          log(
            :info,
            :cgroup,
            "Skip #{path}, group or parameter does not exist"
          )
          next
        end
      end

      failed
    end

    def reset_value(param)
      case param.name
      when 'cpu.cfs_quota_us'
        [-1]

      when 'memory.limit_in_bytes', 'memory.memsw.limit_in_bytes'
        [-1]

      else
        nil
      end
    end
  end
end
