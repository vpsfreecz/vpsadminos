require 'osctld/cgroup'
require 'osctld/cgroup/cpuset_policy'

module OsCtld
  # Applies a CPU bandwidth limit to the stable container policy root and its
  # complete live hierarchy.
  #
  # The v1 scheduler rejects a finite child bandwidth which is greater than a
  # finite parent bandwidth. A limit increase must therefore be written from
  # root to leaves and a decrease from leaves to root. Quota and period are
  # separate files, so the complete v1 transaction is simulated before the
  # first write. A live transition is rejected when neither write order keeps
  # every effective bandwidth between its old and new values. Cgroup v2
  # exposes the same policy atomically through cpu.max.
  class CGroup::CpuBandwidthPolicy
    QUOTA_PARAMETER = 'cpu.cfs_quota_us'.freeze
    PERIOD_PARAMETER = 'cpu.cfs_period_us'.freeze
    V2_PARAMETER = 'cpu.max'.freeze
    V1_PARAMETERS = [QUOTA_PARAMETER, PERIOD_PARAMETER].freeze
    PARAMETERS = (V1_PARAMETERS + [V2_PARAMETER]).freeze
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
        quota == -1
      end
    end

    Entry = Struct.new(
      :path,
      :depth,
      :current,
      :effective,
      :managed_role,
      :generation_role,
      :generation_root,
      keyword_init: true
    )

    Step = Struct.new(
      :path,
      :parameter,
      :before,
      :after,
      keyword_init: true
    )

    Result = Struct.new(:target, :rollback_proc, keyword_init: true) do
      def rollback!
        return true unless rollback_proc

        error = rollback_proc.call
        raise error if error

        self.rollback_proc = nil
        true
      end
    end

    class Error < CGroup::CpusetPolicy::Error; end

    # @param ct [Container]
    # @param params [Array<CGroup::Param>] configured CPU bandwidth params
    # @param root [String] absolute stable container cpu cgroup
    def initialize(ct, params, root:)
      @ct = ct
      @params = params
      @root = File.expand_path(root)
    end

    # @return [Result]
    def apply
      CGroup.sync do
        preflight
        journal = []
        preparation_started = false
        target = nil

        begin
          preparation_started = true
          prepare
          entries = scan_entries
          target = target_state(entries)
          validate_target!(target)
          desired = desired_states(entries, target)
          plan = build_plan(entries, desired)
          execute_plan(plan, journal)
          verify!(desired, target)
        rescue StandardError => e
          rollback_error = rollback(journal)
          rollback_error ||= preparation_rollback_error \
            if preparation_started
          message = "unable to apply CPU bandwidth policy: #{e.message}"
          if rollback_error
            message = "#{message}; rollback failed: #{rollback_error.message}"
          end
          raise Error.new(message, rollback_error:)
        end

        preparation_error =
          preparation_started ? preparation_rollback_error : nil
        Result.new(
          target: dump_state(target),
          rollback_proc: proc do
            CGroup.sync do
              rollback(journal) || preparation_error
            end
          end
        )
      end
    end

    protected

    attr_reader :ct, :params, :root

    def preflight; end

    def prepare; end

    def preparation_rollback_error; end

    def scan_entries
      unless File.exist?(parameter_path(root))
        raise Error, "CPU cgroup does not exist at #{root}"
      end

      managed, generations = topology_metadata
      paths = [root]
      paths.concat(
        Dir.glob(File.join(root, '**', parameter_name)).map do |parameter|
          File.dirname(parameter)
        end
      )

      entries = paths.uniq.map do |path|
        generation = generations
                     .select { |item| descendant?(path, item.fetch(:root)) }
                     .max_by { |item| item.fetch(:root).length }

        Entry.new(
          path:,
          depth: relative_depth(path),
          current: read_state(path),
          effective: nil,
          managed_role: managed[path],
          generation_role: generation && generation.fetch(:role),
          generation_root: generation && generation.fetch(:root)
        )
      end.sort_by { |entry| [entry.depth, entry.path] }

      parent_effective = effective_state(File.dirname(root))
      entries.each do |entry|
        ancestor =
          if entry.path == root
            parent_effective
          else
            entries
              .take_while { |candidate| candidate.depth < entry.depth }
              .reverse_each
              .detect { |candidate| descendant?(entry.path, candidate.path) }
              &.effective
          end
        entry.effective =
          ancestor ? narrower(entry.current, ancestor) : copy_state(entry.current)
      end

      entries
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

      return configured_v2_state(stable.current, params) if CGroup.v2?

      quota =
        configured_value(QUOTA_PARAMETER, params) || stable.current.quota
      period =
        configured_value(PERIOD_PARAMETER, params) || stable.current.period
      State.new(quota:, period:)
    end

    def configured_v2_state(current, configured_params)
      param = configured_params.reverse_each.detect do |candidate|
        candidate.name == V2_PARAMETER
      end
      return copy_state(current) unless param

      parse_v2_state(param.value.last, current.period)
    end

    def configured_value(name, configured_params)
      param = configured_params.reverse_each.detect do |candidate|
        candidate.name == name
      end
      return unless param

      value = Integer(param.value.last.to_s, 10)
      if name == QUOTA_PARAMETER && value < -1
        raise ArgumentError
      end

      value
    rescue ArgumentError, TypeError
      raise Error, "invalid #{name} value #{param.value.last.inspect}"
    end

    def desired_states(entries, target)
      entries.to_h do |entry|
        desired =
          if entry.generation_role == :residual
            if entry.path == entry.generation_root
              narrower(entry.effective, target)
            else
              unlimited_state(entry.current)
            end
          elsif entry.managed_role == :active
            unlimited_state(entry.current)
          elsif entry.path == root \
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
    end

    def validate_state!(state, path)
      if state.period <= 0
        raise Error, "invalid CPU period #{state.period} at #{path}"
      end
      return if state.unlimited? || state.quota > 0

      raise Error, "invalid CPU quota #{state.quota} at #{path}"
    end

    def build_plan(entries, desired)
      planned_entries = entries.map do |entry|
        Entry.new(
          path: entry.path,
          depth: entry.depth,
          current: copy_state(entry.current),
          effective: copy_state(entry.effective),
          managed_role: entry.managed_role,
          generation_role: entry.generation_role,
          generation_root: entry.generation_root
        )
      end
      final_entries = planned_entries.map do |entry|
        entry.dup.tap do |copy|
          copy.current = copy_state(desired.fetch(entry.path))
        end
      end

      @transition_entries = planned_entries
      @transition_parent_effective = effective_state(File.dirname(root))
      @transition_initial_effective = effective_states(planned_entries)
      @transition_final_effective = effective_states(final_entries)
      @transition_plan = []
      apply_states(planned_entries, desired)
      @transition_plan
    ensure
      @transition_entries = nil
      @transition_parent_effective = nil
      @transition_initial_effective = nil
      @transition_final_effective = nil
      @transition_plan = nil
    end

    def apply_states(entries, desired)
      # Transfer each residual's effective grant to its osctld-owned generation
      # root before expanding an ancestor. Descendants are then made unlimited,
      # so an LXC-owned cgroup can disappear without leaving a finite scheduler
      # object behind.
      entries.each do |entry|
        next unless entry.generation_role == :residual
        next unless entry.path == entry.generation_root
        next unless compare(entry.current, entry.effective) > 0

        transition(entry, entry.effective)
      end

      # Release finite LXC-owned payloads before changing any ancestor. LXC
      # teardown is not serialized by CGroup.sync and can remove a payload at
      # any time. Once the unlimited write succeeds, asynchronous removal
      # cannot leave an invisible finite v1 scheduler object. Residual
      # descendants are released deepest-first below the generation-root pin.
      entries.reverse_each do |entry|
        wanted = desired.fetch(entry.path)
        next unless release_before_ancestor_update?(entry, wanted)

        transition(entry, wanted)
      end

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
    end

    def release_before_ancestor_update?(entry, wanted)
      return false unless wanted.unlimited?
      return true if entry.managed_role == :active

      entry.generation_role == :residual \
        && entry.path != entry.generation_root
    end

    def transition(entry, wanted)
      current = entry.current
      return if same_state?(current, wanted)

      validate_state!(wanted, entry.path)

      if CGroup.v2?
        append_step(entry, V2_PARAMETER, wanted)
        return
      end

      parameter_order(entry, current, wanted).each do |parameter|
        value = parameter_value(wanted, parameter)
        next if parameter_value(current, parameter) == value

        updated =
          if parameter == QUOTA_PARAMETER
            State.new(quota: value, period: current.period)
          else
            State.new(quota: current.quota, period: value)
          end
        append_step(entry, parameter, updated)
        current = updated
      end
    end

    def parameter_order(entry, current, wanted)
      changed = V1_PARAMETERS.reject do |parameter|
        parameter_value(current, parameter) == parameter_value(wanted, parameter)
      end
      candidates =
        if changed.length < 2
          [changed]
        elsif wanted.unlimited?
          [[QUOTA_PARAMETER, PERIOD_PARAMETER]]
        elsif current.unlimited?
          [[PERIOD_PARAMETER, QUOTA_PARAMETER]]
        else
          [
            [QUOTA_PARAMETER, PERIOD_PARAMETER],
            [PERIOD_PARAMETER, QUOTA_PARAMETER]
          ]
        end
      selected = candidates.detect do |order|
        transition_order_valid?(entry, current, wanted, order)
      end

      unless selected
        raise Error,
              'cannot transition CPU bandwidth monotonically from ' \
              "#{format_state(current)} to #{format_state(wanted)} at " \
              "#{entry.path} while live; stop the container or retain its " \
              'current CPU period'
      end

      selected
    end

    def transition_order_valid?(entry, current, wanted, order)
      simulated = copy_state(current)

      order.all? do |parameter|
        simulated =
          if parameter == QUOTA_PARAMETER
            State.new(quota: wanted.quota, period: simulated.period)
          else
            State.new(quota: simulated.quota, period: wanted.period)
          end

        transition_state_valid?(entry, simulated)
      end
    ensure
      entry.current = current
    end

    def transition_state_valid?(entry, candidate)
      return false unless hierarchy_valid?(entry, candidate)

      entry.current = copy_state(candidate)
      current_effective = effective_states(@transition_entries)

      current_effective.all? do |path, current|
        initial = @transition_initial_effective.fetch(path)
        final = @transition_final_effective.fetch(path)

        case compare(final, initial)
        when -1
          compare(current, initial) <= 0 && compare(current, final) >= 0
        when 0
          compare(current, initial) == 0
        when 1
          compare(current, initial) >= 0 && compare(current, final) <= 0
        end
      end
    end

    def hierarchy_valid?(entry, candidate)
      return true if CGroup.v2?
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

    def effective_states(entries)
      entries.each_with_object({}) do |entry, ret|
        ancestor =
          if entry.path == root
            @transition_parent_effective
          else
            entries
              .take_while { |candidate| candidate.depth < entry.depth }
              .reverse_each
              .detect { |candidate| descendant?(entry.path, candidate.path) }
              .then { |candidate| candidate && ret.fetch(candidate.path) }
          end
        ret[entry.path] =
          if ancestor
            narrower(entry.current, ancestor)
          else
            copy_state(entry.current)
          end
      end
    end

    def append_step(entry, parameter, wanted)
      before = copy_state(entry.current)
      after = copy_state(wanted)
      unless transition_state_valid?(entry, after)
        raise Error,
              'cannot transition CPU bandwidth monotonically from ' \
              "#{format_state(before)} to #{format_state(after)} at " \
              "#{entry.path}"
      end

      @transition_plan << Step.new(
        path: entry.path,
        parameter:,
        before:,
        after:
      )
      entry.current = after
    end

    def execute_plan(plan, journal)
      plan.each do |step|
        actual = read_state(step.path)
        unless same_state?(actual, step.before)
          raise Error,
                "#{step.path} changed CPU bandwidth from " \
                "#{format_state(step.before)} to #{format_state(actual)} " \
                'after policy preflight'
        end

        write_step(step, step.after)
        journal << step
      end
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

      current.each do |entry|
        next if target.unlimited?
        next unless compare(entry.effective, target) > 0

        raise Error,
              "#{entry.path} has CPU bandwidth " \
              "#{format_state(entry.effective)}, outside " \
              "#{format_state(target)}"
      end
    end

    def rollback(journal)
      journal.reverse_each do |step|
        actual = read_state(step.path)
        unless same_state?(actual, step.after)
          raise Error,
                "#{step.path} changed CPU bandwidth from " \
                "#{format_state(step.after)} to #{format_state(actual)} " \
                'before policy rollback'
        end

        write_step(step, step.before)
        restored = read_state(step.path)
        next if same_state?(restored, step.before)

        raise Error,
              "rollback restored #{format_state(restored)} at #{step.path}, " \
              "expected #{format_state(step.before)}"
      end

      nil
    rescue StandardError => e
      e
    end

    def read_state(path)
      if CGroup.v2?
        return parse_v2_state(
          File.read(File.join(path, V2_PARAMETER)).strip,
          nil
        ).tap { |state| validate_state!(state, path) }
      end

      State.new(
        quota: Integer(File.read(File.join(path, QUOTA_PARAMETER)).strip, 10),
        period: Integer(File.read(File.join(path, PERIOD_PARAMETER)).strip, 10)
      ).tap { |state| validate_state!(state, path) }
    end

    def parse_v2_state(value, default_period)
      fields = value.to_s.split
      raise ArgumentError unless fields.length.between?(1, 2)

      quota_value, period_value = fields
      quota =
        if quota_value == 'max'
          -1
        else
          Integer(quota_value, 10).tap do |parsed_quota|
            raise ArgumentError if parsed_quota < 0
          end
        end
      period =
        if period_value
          Integer(period_value, 10)
        elsif default_period
          default_period
        else
          raise ArgumentError
        end

      State.new(quota:, period:)
    rescue ArgumentError, TypeError
      raise Error, "invalid #{V2_PARAMETER} value #{value.inspect}"
    end

    def write(path, parameter, value)
      file = File.join(path, parameter)
      return if CGroup.set_param(file, [value])

      raise Error, "kernel rejected #{parameter}=#{value} at #{path}"
    end

    def write_state(path, state)
      value = "#{state.unlimited? ? 'max' : state.quota} #{state.period}"
      file = File.join(path, V2_PARAMETER)
      return if CGroup.set_param(file, [value])

      raise Error, "kernel rejected #{V2_PARAMETER}=#{value} at #{path}"
    end

    def write_step(step, state)
      if step.parameter == V2_PARAMETER
        write_state(step.path, state)
      else
        write(
          step.path,
          step.parameter,
          parameter_value(state, step.parameter)
        )
      end
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

    def narrower(left, right)
      compare(left, right) <= 0 ? copy_state(left) : copy_state(right)
    end

    def effective_state(path)
      states = []
      current = File.expand_path(path)

      loop do
        states << read_state(current) if File.exist?(parameter_path(current))
        parent = File.dirname(current)
        break if parent == current

        current = parent
      end

      states.reduce { |effective, state| narrower(effective, state) }
    end

    def copy_state(state)
      State.new(quota: state.quota, period: state.period)
    end

    def unlimited_state(state)
      State.new(quota: -1, period: state.period)
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

    def parameter_name
      CGroup.v2? ? V2_PARAMETER : QUOTA_PARAMETER
    end

    def parameter_path(path)
      File.join(path, parameter_name)
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
