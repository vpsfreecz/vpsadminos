require 'libosctl'
require 'osctld/lockable'
require 'osctld/cgroup/cpuset_policy'
require 'osctld/cgroup/group_cpu_bandwidth_policy'
require 'osctld/cgroup/group_cpuset_policy'

module OsCtld
  class CGroup::Params
    include Lockable
    include OsCtl::Lib::Utils::Log

    class ApplyResult
      def initialize
        @policies = []
      end

      def add(policy_result)
        @policies << policy_result if policy_result.respond_to?(:rollback!)
      end

      def rollback!
        errors = []
        @policies.reverse_each do |policy|
          policy.rollback!
        rescue StandardError => e
          errors << e
        end
        @policies.clear
        return true if errors.empty?

        raise CGroup::CpusetPolicy::Error,
              errors.map(&:message).join('; ')
      end
    end

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

    # Strict group transaction used whenever a parent cgroup policy can affect
    # descendant container hierarchies.
    def transactional_set(
      new_params,
      append: false,
      apply: true,
      cpuset: true,
      cpu_bandwidth: true,
      force_cpu_bandwidth: false,
      cpu_bandwidth_resets: [],
      policy_containers: nil,
      &path
    )
      before = snapshot_params
      set(new_params, append:, save: false)
      staged = snapshot_params
      if apply
        validate_runtime_resets!(
          added_params(before, staged)
        )
      end

      parameter_transaction(
        before,
        staged:,
        apply_runtime: apply,
        cpuset:,
        cpu_bandwidth:,
        policy_containers:,
        path:
      ) do
        if apply
          self.apply(
            keep_going: true,
            cpuset:,
            cpu_bandwidth:,
            force_cpu_bandwidth:,
            cpu_bandwidth_resets:,
            policy_containers:,
            &path
          )
        end
      end
    rescue StandardError
      restore_params(before) if before
      raise
    end

    # @param save [Boolean] save config file
    # @param reset [Boolean] reset cgroup parameter value
    # @param keep_going [Boolean] skip parameters that do not exist
    # @yieldparam subsystem [String] cgroup subsystem
    # @yieldreturn [String] absolute path to the cgroup directory
    def unset(del_params, save: true, reset: true, keep_going: false, &)
      exclusively do
        del_params.each do |del_h|
          del_p = CGroup::Param.import(del_h)

          params.delete_if do |p|
            del = p.version == del_p.version \
                  && p.subsystem == del_p.subsystem \
                  && p.name == del_p.name
            next(del) unless del

            reset(p, keep_going, &) if reset && p.version == CGroup.version
            true
          end
        end
      end

      owner.save_config if save
    end

    def transactional_unset(
      del_params,
      reset: true,
      keep_going: false,
      apply_all: false,
      cpuset: true,
      cpu_bandwidth: true,
      force_cpu_bandwidth: false,
      cpu_bandwidth_resets: [],
      policy_containers: nil,
      &path
    )
      before = snapshot_params
      imported = del_params.map { |spec| CGroup::Param.import(spec) }
      deleted = before.select do |param|
        imported.any? { |candidate| same_param?(param, candidate) }
      end
      staged = before.reject do |param|
        deleted.any? { |candidate| same_param?(param, candidate) }
      end
      validate_runtime_resets!(deleted) if reset
      restore_params(staged)
      cpu_bandwidth_removed = deleted.any? do |param|
        group_cpu_bandwidth_param?(param)
      end

      parameter_transaction(
        before,
        staged:,
        apply_runtime: reset,
        cpuset:,
        cpu_bandwidth:,
        policy_containers:,
        path:
      ) do
        if reset
          deleted.each do |param|
            next if group_cpu_bandwidth_param?(param)

            reset(param, keep_going, &path) if param.version == CGroup.version
          end
        end
        if apply_all || cpu_bandwidth_removed || force_cpu_bandwidth
          apply(
            keep_going: true,
            cpuset:,
            cpu_bandwidth:,
            force_cpu_bandwidth:
              cpu_bandwidth_removed || force_cpu_bandwidth,
            cpu_bandwidth_resets:
              merge_cpu_bandwidth_resets(
                cpu_bandwidth_resets,
                deleted
              ),
            policy_containers:,
            &path
          )
        end
      end
    end

    def each(&)
      params.each(&)
    end

    # @param version [1, 2]
    def each_version(version, &)
      params.select { |p| p.version == version }.each(&)
    end

    def each_usable(&)
      each_version(CGroup.version, &)
    end

    def detect(&)
      params.detect(&)
    end

    # Apply configured cgroup parameters into the system
    # @param keep_going [Boolean] skip parameters that do not exist
    # @yieldparam subsystem [String] cgroup subsystem
    # @yieldreturn [String] absolute path to the cgroup directory
    def apply(
      keep_going: false,
      cpuset: true,
      only_cpuset: false,
      cpu_bandwidth: true,
      force_cpu_bandwidth: false,
      cpu_bandwidth_resets: [],
      policy_containers: nil,
      &path
    )
      selected =
        if only_cpuset
          if cpuset
            usable_params.select { |param| param.name == 'cpuset.cpus' }
          else
            []
          end
        elsif cpuset
          usable_params
        else
          usable_params.reject { |param| param.name == 'cpuset.cpus' }
        end
      cpu_params, generic =
        if owner.is_a?(Group) && !only_cpuset
          policy, ordinary =
            selected.partition { |param| group_cpu_bandwidth_param?(param) }
          [cpu_bandwidth ? policy : [], ordinary]
        else
          [[], selected]
        end
      cpuset_params, generic =
        if owner.is_a?(Group) && !only_cpuset
          policy, ordinary =
            generic.partition { |param| param.name == 'cpuset.cpus' }
          [cpuset ? policy : [], ordinary]
        else
          [[], generic]
        end
      cpu_policy =
        if owner.is_a?(Group) \
            && cpu_bandwidth \
            && (force_cpu_bandwidth || cpu_params.any?)
          policy_opts = {
            reconstruct_to: owner,
            containers: policy_containers
          }
          policy_opts[:resets] = cpu_bandwidth_resets \
            unless cpu_bandwidth_resets.empty?
          CGroup::GroupCpuBandwidthPolicy.new(
            owner,
            **policy_opts
          )
        end
      cpuset_policy =
        if owner.is_a?(Group) && cpuset && cpuset_params.any?
          CGroup::GroupCpusetPolicy.new(owner, reconstruct_to: owner)
        end
      result = ApplyResult.new

      begin
        result.add(cpu_policy.apply) if cpu_policy
        result.add(cpuset_policy.apply) if cpuset_policy

        failed = apply_params_and_retry(generic, keep_going:, &path)
        unless failed.empty?
          names = failed.map(&:name).uniq.join(', ')
          raise CGroup::CpusetPolicy::Error,
                "kernel rejected group cgroup parameters: #{names}"
        end

        selected.each do |param|
          next unless param.name == 'cpuset.cpus'

          verify_cpuset_path(
            path.call(param.subsystem),
            param.value.last.to_s
          )
        end
      rescue StandardError => e
        rollback_errors = []
        if e.respond_to?(:rollback_error) && e.rollback_error
          rollback_errors << e.rollback_error
        end
        begin
          result.rollback!
        rescue StandardError => rollback
          rollback_errors << rollback
        end
        rollback_error = combine_rollback_errors(rollback_errors)
        message = e.message
        missing_rollback_messages = rollback_errors
                                    .map(&:message)
                                    .uniq
                                    .reject { |item| message.include?(item) }
        unless missing_rollback_messages.empty?
          message = "#{message}; rollback failed: " \
                    "#{missing_rollback_messages.join('; ')}"
        end
        raise CGroup::CpusetPolicy::Error.new(
          message,
          rollback_error:,
          cleanup_params:
            e.respond_to?(:cleanup_params) ? e.cleanup_params : [],
          policy_compensated: rollback_error.nil?
        )
      end

      result
    end

    # Replace all parameters by a new list of parameters
    # @param new_params [Array<CGroup::Param>]
    # @param save [Boolean] update the owner's config file
    def replace(new_params, save: true, &)
      @params.each do |p|
        found = new_params.detect do |n|
          n.version == p.version && n.subsystem == p.subsystem && n.name == p.name
        end

        reset(p, true, &) if !found && p.version == CGroup.version
      end

      @params = new_params
      owner.save_config if save
    end

    def transactional_replace(
      new_params,
      cpuset: true,
      cpu_bandwidth: true,
      force_cpu_bandwidth: false,
      cpu_bandwidth_resets: [],
      policy_containers: nil,
      &path
    )
      before = snapshot_params
      staged = copy_params(new_params)
      removed = before.reject do |param|
        staged.any? { |candidate| same_param?(param, candidate) }
      end
      validate_runtime_resets!(
        removed + added_params(before, staged)
      )
      restore_params(staged)

      parameter_transaction(
        before,
        staged:,
        apply_runtime: true,
        cpuset:,
        cpu_bandwidth:,
        policy_containers:,
        path:
      ) do
        removed.each do |param|
          next if group_cpu_bandwidth_param?(param)

          reset(param, true, &path) if param.version == CGroup.version
        end
        apply(
          keep_going: true,
          cpuset:,
          cpu_bandwidth:,
          force_cpu_bandwidth:
            force_cpu_bandwidth \
            || removed.any? { |param| group_cpu_bandwidth_param?(param) },
          cpu_bandwidth_resets:
            merge_cpu_bandwidth_resets(
              cpu_bandwidth_resets,
              removed
            ),
          policy_containers:,
          &path
        )
      end
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
      path = File.join(yield(param.subsystem), param.name)
      value =
        if param.name == 'cpuset.cpus'
          [
            CGroup::CpusetPolicy.read_effective_mask(
              File.dirname(path, 2)
            )
          ]
        else
          reset_value(param)
        end
      unless value
        raise CGroup::CpusetPolicy::Error,
              "no runtime reset value is known for #{param.name}"
      end
      if CGroup.set_param(path, value)
        if param.name == 'cpuset.cpus'
          verify_cpuset_path(File.dirname(path), value.last.to_s)
        end
        return
      end

      raise CGroup::CpusetPolicy::Error,
            "kernel rejected group cgroup parameter #{param.name}"
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
      end
    end

    # Find CPU limit
    # @return [Integer, nil] CPU limit in percent (100 % for one CPU)
    def find_cpu_limit
      if CGroup.v2?
        each_usable do |p|
          next if p.name != 'cpu.max'

          quota, period = p.value.last.split

          return nil if quota == 'max'

          return ((quota.to_f / period.to_i) * 100).round
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
          return ((quota.to_f / period) * 100).round
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
      ret.instance_variable_set(
        '@params',
        params.map do |param|
          param.clone.tap { |copy| copy.value = param.value.dup }
        end
      )
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

    def apply_params_and_retry(param_list, keep_going: false, &)
      failed = apply_params(
        param_list,
        keep_going:,
        &
      )
      memory, final = failed.partition do |param|
        param.name.start_with?('memory.')
      end

      if memory.any?
        final.concat(apply_params(memory, keep_going:, &))
      end

      final
    end

    def reset_value(param)
      case param.name
      when 'cpu.cfs_quota_us', 'memory.limit_in_bytes', 'memory.memsw.limit_in_bytes'
        [-1]

      when 'cpu.cfs_period_us'
        [100_000]

      when 'cpu.max', 'memory.high', 'memory.max', 'memory.swap.max', 'pids.max'
        ['max']

      when 'memory.min', 'memory.low'
        [0]
      end
    end

    def verify_cpuset_path(cgroup_path, target)
      explicit = File.read(File.join(cgroup_path, 'cpuset.cpus')).strip
      effective = CGroup::CpusetPolicy.read_effective_mask(cgroup_path)
      expected = OsCtl::Lib::CpuMask.new(target).to_s
      requested = OsCtl::Lib::CpuMask.new(explicit).to_s
      return if requested == expected && effective == expected

      raise CGroup::CpusetPolicy::Error,
            "group cpuset verification failed at #{cgroup_path}: " \
            "requested=#{requested.inspect}, effective=#{effective.inspect}, " \
            "expected=#{expected.inspect}"
    end

    def parameter_transaction(
      before,
      staged:,
      apply_runtime:,
      path:,
      cpuset: true,
      cpu_bandwidth: true,
      policy_containers: nil
    )
      owner.save_config
      yield
    rescue StandardError => e
      restore_params(before)
      rollback_errors = []
      if e.respond_to?(:rollback_error) && e.rollback_error
        rollback_errors << e.rollback_error
      end
      policy_compensated =
        e.respond_to?(:policy_compensated) && e.policy_compensated

      if apply_runtime
        begin
          added = added_params(before, staged)
          added.each do |param|
            next unless param.version == CGroup.version
            next if group_cpu_bandwidth_param?(param)
            next if policy_compensated && param.name == 'cpuset.cpus'

            reset(param, true, &path)
          end
          apply(
            keep_going: true,
            cpuset: cpuset && !policy_compensated,
            cpu_bandwidth: cpu_bandwidth && !policy_compensated,
            force_cpu_bandwidth:
              !policy_compensated \
              && added.any? { |param| group_cpu_bandwidth_param?(param) },
            policy_containers:,
            &path
          )
        rescue StandardError => rollback
          rollback_errors << rollback
        end
      end

      begin
        owner.save_config
      rescue StandardError => rollback
        rollback_errors << rollback
      end

      message = "unable to update group cgroup parameters: #{e.message}"
      rollback_error = combine_rollback_errors(rollback_errors)
      if rollback_error
        missing_rollback_messages = rollback_errors
                                    .map(&:message)
                                    .uniq
                                    .reject { |item| message.include?(item) }
        unless missing_rollback_messages.empty?
          message = "#{message}; rollback failed: " \
                    "#{missing_rollback_messages.join('; ')}"
        end
      end
      raise CGroup::CpusetPolicy::Error.new(
        message,
        rollback_error:,
        cleanup_params:
          added_params(before, staged)
            .select { |param| param.version == CGroup.version }
            .map(&:dump)
      )
    end

    def validate_runtime_resets!(param_list)
      unsupported = param_list.select do |param|
        param.version == CGroup.version \
          && param.name != 'cpuset.cpus' \
          && reset_value(param).nil?
      end
      return if unsupported.empty?

      names = unsupported.map(&:name).uniq.join(', ')
      raise CGroup::CpusetPolicy::Error,
            "no runtime reset value is known for #{names}"
    end

    def added_params(before, staged)
      staged.reject do |param|
        before.any? { |old_param| same_param?(param, old_param) }
      end
    end

    def merge_cpu_bandwidth_resets(*lists)
      lists
        .flatten
        .select { |param| group_cpu_bandwidth_param?(param) }
        .uniq { |param| [param.version, param.subsystem, param.name] }
    end

    def combine_rollback_errors(errors)
      unique = errors.compact.uniq(&:message)
      return if unique.empty?
      return unique.first if unique.length == 1

      CGroup::CpusetPolicy::Error.new(
        unique.map(&:message).join('; ')
      )
    end

    def snapshot_params
      exclusively { copy_params(params) }
    end

    def restore_params(new_params)
      exclusively { @params = copy_params(new_params) }
    end

    def copy_params(list)
      list.map do |param|
        param.clone.tap { |copy| copy.value = param.value.dup }
      end
    end

    def same_param?(left, right)
      left.version == right.version \
        && left.subsystem == right.subsystem \
        && left.name == right.name
    end

    def group_cpu_bandwidth_param?(param)
      return false unless owner.is_a?(Group)
      return false unless param.version == CGroup.version

      CGroup::CpuBandwidthPolicy::PARAMETERS.include?(param.name)
    end
  end
end
