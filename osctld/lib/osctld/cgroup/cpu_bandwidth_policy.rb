require 'osctld/cgroup'
require 'osctld/cgroup/cpuset_policy'

module OsCtld
  # Applies a cgroup-v1 CFS bandwidth limit to the stable container policy
  # root and its complete live hierarchy.
  #
  # The v1 scheduler rejects a finite child bandwidth which is greater than a
  # finite parent bandwidth. A limit increase must therefore be written from
  # root to leaves and a decrease from leaves to root. Quota and period are
  # separate files, so each node also needs a monotonic two-write transition.
  class CGroup::CpuBandwidthPolicy
    QUOTA_PARAMETER = 'cpu.cfs_quota_us'.freeze
    PERIOD_PARAMETER = 'cpu.cfs_period_us'.freeze
    PARAMETERS = [QUOTA_PARAMETER, PERIOD_PARAMETER].freeze
    CGROUP_RESOURCE_KEYS = %w[
      cgroup_root
      user_cgroup
      wrapper_cgroup
      host_effects
      lxc_payload
      lxc_monitor
      lxc_pivot
      lxc_inner
    ].freeze

    State = Struct.new(:quota, :period, keyword_init: true) do
      def unlimited?
        quota < 0
      end
    end

    Entry = Struct.new(
      :path,
      :depth,
      :current,
      :managed_role,
      :generation_role,
      keyword_init: true
    )

    Result = Struct.new(:target, keyword_init: true)

    class Error < CGroup::CpusetPolicy::Error; end

    # @param ct [Container]
    # @param params [Array<CGroup::Param>] configured v1 quota/period params
    # @param root [String] absolute stable container cpu cgroup
    def initialize(ct, params, root:)
      @ct = ct
      @params = params
      @root = File.expand_path(root)
    end

    # @return [Result]
    def apply
      CGroup.sync do
        entries = scan_entries
        originals = entries.to_h do |entry|
          [entry.path, copy_state(entry.current)]
        end
        target = target_state(entries)
        validate_target!(target)
        desired = desired_states(entries, target)

        begin
          apply_states(entries, desired)
          verify!(desired, target)
        rescue StandardError => e
          rollback_error = rollback(originals)
          message = "unable to apply CPU bandwidth policy: #{e.message}"
          if rollback_error
            message = "#{message}; rollback failed: #{rollback_error.message}"
          end
          raise Error.new(message, rollback_error:)
        end

        Result.new(target: dump_state(target))
      end
    end

    protected

    attr_reader :ct, :params, :root

    def scan_entries
      unless File.exist?(File.join(root, QUOTA_PARAMETER))
        raise Error, "CPU cgroup does not exist at #{root}"
      end

      managed, generations = topology_metadata
      paths = [root]
      paths.concat(
        Dir.glob(File.join(root, '**', QUOTA_PARAMETER)).map do |parameter|
          File.dirname(parameter)
        end
      )

      paths.uniq.map do |path|
        generation = generations
                     .select { |item| descendant?(path, item.fetch(:root)) }
                     .max_by { |item| item.fetch(:root).length }

        Entry.new(
          path:,
          depth: relative_depth(path),
          current: read_state(path),
          managed_role: managed[path],
          generation_role: generation && generation.fetch(:role)
        )
      end.sort_by { |entry| [entry.depth, entry.path] }
    rescue Errno::ENOENT => e
      raise Error, "cgroup topology changed while scanning: #{e.message}"
    end

    def topology_metadata
      managed = {}
      generations = []

      ct.lifecycle.runs.each_value do |run|
        role = run.fetch('role').to_sym
        next unless %i[active residual].include?(role)

        resources = run.fetch('resources')
        run_root = abs_path(resources.fetch('cgroup_root'))
        generations << { root: run_root, role: }

        CGROUP_RESOURCE_KEYS.each do |key|
          path = resources[key]
          next unless path

          absolute = abs_path(path)
          next unless descendant?(absolute, root)

          managed[absolute] = role if key == 'lxc_payload'
        end
      end

      [managed, generations]
    end

    def target_state(entries)
      stable = entries.detect { |entry| entry.path == root }
      raise Error, "stable CPU cgroup #{root} is missing" unless stable

      quota = configured_value(QUOTA_PARAMETER) || stable.current.quota
      period = configured_value(PERIOD_PARAMETER) || stable.current.period
      State.new(quota:, period:)
    end

    def configured_value(name)
      param = params.reverse_each.detect { |candidate| candidate.name == name }
      return unless param

      value = Integer(param.value.last.to_s, 10)
      name == QUOTA_PARAMETER && value < 0 ? -1 : value
    rescue ArgumentError, TypeError
      raise Error, "invalid #{name} value #{param.value.last.inspect}"
    end

    def desired_states(entries, target)
      entries.to_h do |entry|
        desired =
          if entry.path == root \
             || entry.managed_role == :active \
             || (!entry.current.unlimited? \
                 && !target.unlimited? \
                 && compare(entry.current, target) > 0)
            target
          else
            entry.current
          end

        [entry.path, copy_state(desired)]
      end
    end

    def validate_target!(target)
      validate_state!(target, root)

      parent = File.dirname(root)
      return unless File.exist?(File.join(parent, QUOTA_PARAMETER))

      parent_state = read_state(parent)
      return if parent_state.unlimited?
      return unless compare(target, parent_state) > 0

      raise Error,
            "CPU bandwidth #{format_state(target)} exceeds parent " \
            "#{format_state(parent_state)} at #{parent}"
    end

    def validate_state!(state, path)
      if state.period <= 0
        raise Error, "invalid CPU period #{state.period} at #{path}"
      end
      return if state.unlimited? || state.quota > 0

      raise Error, "invalid CPU quota #{state.quota} at #{path}"
    end

    def apply_states(entries, desired)
      @transition_entries = entries

      # First make every configured boundary broad enough for both its current
      # and final bandwidth. Parents are expanded before their children.
      entries.each do |entry|
        wanted = desired.fetch(entry.path)
        expanded =
          if compare(entry.current, wanted) < 0
            wanted
          else
            entry.current
          end
        transition(entry, expanded)
      end

      # Then commit the final limits from leaves to root. This is the ordering
      # required by cgroup v1 when a parent bandwidth is reduced.
      entries.reverse_each do |entry|
        transition(entry, desired.fetch(entry.path))
      end
    ensure
      @transition_entries = nil
    end

    def transition(entry, wanted)
      current = entry.current
      return if same_state?(current, wanted)

      validate_state!(wanted, entry.path)
      parameter_order(entry, current, wanted).each do |parameter|
        value =
          if parameter == QUOTA_PARAMETER
            wanted.quota
          else
            wanted.period
          end
        next if parameter_value(current, parameter) == value

        write(entry.path, parameter, value)
        current =
          if parameter == QUOTA_PARAMETER
            State.new(quota: value, period: current.period)
          else
            State.new(quota: current.quota, period: value)
          end
        entry.current = current
      end
    end

    def parameter_order(entry, current, wanted)
      changed = PARAMETERS.reject do |parameter|
        parameter_value(current, parameter) == parameter_value(wanted, parameter)
      end
      return changed if changed.length < 2
      return [QUOTA_PARAMETER, PERIOD_PARAMETER] if wanted.unlimited?
      return [PERIOD_PARAMETER, QUOTA_PARAMETER] if current.unlimited?

      candidates = [
        [
          QUOTA_PARAMETER,
          State.new(quota: wanted.quota, period: current.period)
        ],
        [
          PERIOD_PARAMETER,
          State.new(quota: current.quota, period: wanted.period)
        ]
      ]
      selected = candidates.detect do |_parameter, intermediate|
        hierarchy_valid?(entry, intermediate)
      end
      unless selected
        raise Error,
              'cannot transition CPU bandwidth monotonically from ' \
              "#{format_state(current)} to #{format_state(wanted)}"
      end

      first = selected.first
      [first, (PARAMETERS - [first]).first]
    end

    def hierarchy_valid?(entry, candidate)
      return true if candidate.unlimited?

      @transition_entries.each do |other|
        next if other.equal?(entry) || other.current.unlimited?

        if descendant?(entry.path, other.path)
          return false if compare(candidate, other.current) > 0
        elsif descendant?(other.path, entry.path)
          return false if compare(other.current, candidate) > 0
        end
      end

      true
    end

    def verify!(desired, target)
      current = scan_entries
      by_path = current.to_h { |entry| [entry.path, entry] }
      missing = desired.keys - by_path.keys
      unless missing.empty?
        raise Error, "cgroup paths disappeared: #{missing.join(', ')}"
      end

      desired.each do |path, wanted|
        actual = by_path.fetch(path).current
        next if same_state?(actual, wanted)

        raise Error,
              "#{path} has CPU bandwidth #{format_state(actual)}, " \
              "expected #{format_state(wanted)}"
      end

      return if target.unlimited?

      current.each do |entry|
        next if entry.current.unlimited?
        next unless compare(entry.current, target) > 0

        raise Error,
              "#{entry.path} has CPU bandwidth " \
              "#{format_state(entry.current)}, outside " \
              "#{format_state(target)}"
      end
    end

    def rollback(originals)
      entries = originals.filter_map do |path, state|
        next unless File.exist?(File.join(path, QUOTA_PARAMETER))

        Entry.new(
          path:,
          depth: relative_depth(path),
          current: read_state(path)
        ).tap do |entry|
          entry.managed_role = nil
          entry.generation_role = nil
          validate_state!(state, path)
        end
      end.sort_by { |entry| [entry.depth, entry.path] }
      missing = originals.keys - entries.map(&:path)
      unless missing.empty?
        return Error.new("cgroup paths disappeared: #{missing.join(', ')}")
      end

      @transition_entries = entries
      begin
        entries.each do |entry|
          original = originals.fetch(entry.path)
          expanded =
            if compare(entry.current, original) < 0
              original
            else
              entry.current
            end
          transition(entry, expanded)
        end
        entries.reverse_each do |entry|
          transition(entry, originals.fetch(entry.path))
        end
      ensure
        @transition_entries = nil
      end

      nil
    rescue StandardError => e
      e
    end

    def read_state(path)
      State.new(
        quota: Integer(File.read(File.join(path, QUOTA_PARAMETER)).strip, 10),
        period: Integer(File.read(File.join(path, PERIOD_PARAMETER)).strip, 10)
      ).tap { |state| validate_state!(state, path) }
    end

    def write(path, parameter, value)
      file = File.join(path, parameter)
      return if CGroup.set_param(file, [value])

      raise Error, "kernel rejected #{parameter}=#{value} at #{path}"
    end

    def compare(left, right)
      return 0 if left.unlimited? && right.unlimited?
      return 1 if left.unlimited?
      return -1 if right.unlimited?

      (left.quota * right.period) <=> (right.quota * left.period)
    end

    def parameter_value(state, parameter)
      parameter == QUOTA_PARAMETER ? state.quota : state.period
    end

    def same_state?(left, right)
      left.quota == right.quota && left.period == right.period
    end

    def copy_state(state)
      State.new(quota: state.quota, period: state.period)
    end

    def dump_state(state)
      {
        'quota_us' => state.quota,
        'period_us' => state.period
      }
    end

    def format_state(state)
      "#{state.quota}/#{state.period}"
    end

    def abs_path(path)
      File.expand_path(CGroup.abs_cgroup_path('cpu', path))
    end

    def descendant?(path, ancestor)
      path == ancestor || path.start_with?("#{ancestor}/")
    end

    def relative_depth(path)
      return 0 if path == root

      path.delete_prefix("#{root}/").split('/').length
    end
  end
end
