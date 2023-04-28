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

        # Check parameter. We can verify it only when the same cgroup version
        # is used.
        if p.version == CGroup.version
          subsys = CGroup.real_subsystem(p.subsystem)
          path = CGroup.abs_cgroup_path(subsys)

          param = File.join(path, 'osctl', p.name)

          unless File.exist?(param)
            raise CGroupParameterNotFound, "CGroup parameter '#{param}' not found"
          end
        end

        p
      end
    end

    def set(new_params, append: false, save: true)
      exclusively do
        new_params.each do |new_p|
          replaced = false

          params.map! do |p|
            if p.version == new_p.version \
               && p.subsystem == new_p.subsystem \
               && p.name == new_p.name
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
            del = p.version == del_p.version \
                  && p.subsystem == del_p.subsystem \
                  && p.name == del_p.name
            next(del) if !del
            reset(p, keep_going, &block) if reset && p.version == CGroup.version
            true
          end
        end
      end

      owner.save_config if save
    end

    def each(&block)
      params.each(&block)
    end

    # @param version [1, 2]
    def each_version(version, &block)
      params.select { |p| p.version == version }.each(&block)
    end

    def each_usable(&block)
      each_version(CGroup.version, &block)
    end

    def detect(&block)
      params.detect(&block)
    end

    # Apply configured cgroup parameters into the system
    # @param keep_going [Boolean] skip parameters that do not exist
    # @yieldparam subsystem [String] cgroup subsystem
    # @yieldreturn [String] absolute path to the cgroup directory
    def apply(keep_going: false, &block)
      apply_params_and_retry(usable_params, keep_going: keep_going, &block)
    end

    # Replace all parameters by a new list of parameters
    # @param new_params [Array<CGroup::Param>]
    # @param save [Boolean] update the owner's config file
    def replace(new_params, save: true, &block)
      @params.each do |p|
        found = new_params.detect do |n|
          n.version == p.version && n.subsystem == p.subsystem && n.name == p.name
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

    # Find memory limit
    # @return [Integer, nil] memory limit in bytes
    def find_memory_limit
      if CGroup.v2?
        each_usable do |p|
          next if p.name != 'memory.max'

          v = p.value.last.to_i
          return v > 0 ? v : nil
        end

        return nil
      end

      mem_limit = 0
      memsw_limit = 0

      each_usable do |p|
        if p.name == 'memory.limit_in_bytes'
          mem_limit = p.value.last.to_i
        elsif p.name == 'memory.memsw.limit_in_bytes'
          memsw_limit = p.value.last.to_i
        end

        break if mem_limit > 0 && memsw_limit > 0
      end

      if memsw_limit > 0 && memsw_limit < mem_limit
        memsw_limit
      elsif mem_limit > 0
        mem_limit
      else
        nil
      end
    end

    # Find swap limit
    # @return [Integer, nil] swap limit in bytes
    def find_swap_limit
      if CGroup.v2?
        each_usable do |p|
          next if p.name != 'memory.swap.max'

          v = p.value.last.to_i
          return v > 0 ? v : nil
        end

        return nil
      end

      mem_limit = 0
      memsw_limit = 0

      each_usable do |p|
        if p.name == 'memory.limit_in_bytes'
          mem_limit = p.value.last.to_i
        elsif p.name == 'memory.memsw.limit_in_bytes'
          memsw_limit = p.value.last.to_i
        end

        break if mem_limit > 0 && memsw_limit > 0
      end

      if memsw_limit > 0 && memsw_limit < mem_limit
        memsw_limit
      elsif mem_limit > 0
        memsw_limit - mem_limit
      else
        nil
      end
    end

    # Find CPU limit
    # @return [Integer, nil] CPU limit in percent (100 % for one CPU)
    def find_cpu_limit
      if CGroup.v2?
        each_usable do |p|
          next if p.name != 'cpu.max'

          quota, period = p.value.last.split

          if quota == 'max'
            return nil
          else
            return (quota.to_i / period.to_i) * 100
          end
        end

        return nil
      end

      quota = nil
      period = nil

      each_usable do |p|
        if p.name == 'cpu.cfs_quota_us'
          quota = p.value.last.to_i
          return nil if quota == -1
        elsif p.name == 'cpu.cfs_period_us'
          period = p.value.last.to_i
        end

        if quota && period
          return (quota / period) * 100
        end
      end

      nil
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

    def usable_params
      params.select { |p| p.version == CGroup.version }
    end

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

    def apply_params_and_retry(param_list, keep_going: false, &block)
      failed = apply_params(
        param_list,
        keep_going: keep_going,
        &block
      ).select { |p| p.name.start_with?('memory.') }

      if failed.any?
        apply_params(failed, keep_going: keep_going, &block)
      end
    end

    def reset_value(param)
      case param.name
      when 'cpu.cfs_quota_us'
        [-1]

      when 'cpu.max'
        ['max']

      when 'memory.limit_in_bytes', 'memory.memsw.limit_in_bytes'
        [-1]

      when 'memory.min', 'memory.low'
        [0]

      when 'memory.high', 'memory.max'
        ['max']

      else
        nil
      end
    end
  end
end
