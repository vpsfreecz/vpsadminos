require 'osctld/cgroup/cpu_bandwidth_policy'

module OsCtld
  # Applies configured CPU bandwidth for a group subtree as one transaction.
  #
  # Cgroup v1 requires every finite child grant to remain attainable below its
  # parent. A finite configured v1 child wider than its prospective parent is
  # rejected before any path or parameter write; unlimited children remain
  # valid. Cgroup v2 retains wider local requests behind the parent's effective
  # cap.
  #
  # The caller has to hold parent-policy leases for every descendant container.
  # Residual generations are admitted only by the CPU-specific fence and pinned
  # to their pre-transaction effective grant before any ancestor is expanded.
  class CGroup::GroupCpuBandwidthPolicy < CGroup::CpuBandwidthPolicy
    def initialize(anchor, reconstruct_to: nil, containers: nil, resets: [])
      @anchor = anchor
      @groups = [anchor, *anchor.descendants]
      @containers = (containers || anchor.containers_in_subtree).select do |ct|
        ct.base_cgroup_path == anchor.cgroup_path \
          || ct.base_cgroup_path.start_with?("#{anchor.cgroup_path}/")
      end
      @reconstruct_group = validate_reconstruct_group(reconstruct_to)
      @reset_parameters = resets
                          .select do |param|
                            param.version == CGroup.version \
                              && PARAMETERS.include?(param.name)
                          end
                          .map(&:name)
                          .uniq
      @stable_owners = {}
      @active_payload_owners = {}
      super(
        anchor,
        [],
        root: CGroup.abs_cgroup_path('cpu', anchor.cgroup_path)
      )
    end

    def applied?
      CGroup.sync do
        if @reconstruct_group \
            && !File.exist?(
              parameter_path(abs_path(@reconstruct_group.cgroup_path))
            )
          return false
        end
        return false unless File.exist?(parameter_path(root))

        entries = scan_entries
        target = target_state(entries)
        validate_target!(target)
        desired = desired_states(entries, target)
        current = entries.to_h { |entry| [entry.path, entry] }

        desired.all? do |path, wanted|
          entry = current[path]
          next false unless entry
          next true if entry.generation_role == :residual

          same_state?(entry.current, wanted)
        end
      end
    rescue CGroup::CpusetPolicy::Error, SystemCallError, ArgumentError
      false
    end

    def preflight!
      CGroup.sync { preflight }
      true
    end

    protected

    attr_reader :anchor, :groups, :containers

    def preflight
      validate_configured_hierarchy!
      preflight_existing_topology!
    end

    def prepare
      return unless @reconstruct_group

      CGroup.mkpath(
        'cpu',
        @reconstruct_group.cgroup_path.split('/'),
        leaf: false
      )
    end

    def preparation_rollback_error
      return unless @reconstruct_group

      Error.new(
        'requested CPU cgroup path/controller reconstruction cannot be ' \
        'rolled back exactly'
      )
    end

    def validate_reconstruct_group(group)
      return unless group

      unless groups.include?(group)
        raise Error,
              'CPU policy reconstruction target is outside its group subtree'
      end

      group
    end

    def topology_metadata
      managed = {}
      generations = []
      @stable_owners = {}
      @active_payload_owners = {}

      containers.each do |container|
        stable = abs_path(container.base_cgroup_path)
        @stable_owners[stable] = container if descendant?(stable, root)

        container.lifecycle.runs.each_value do |run|
          role = run.fetch('role').to_sym
          next unless %i[active residual].include?(role)

          resources = run.fetch('resources')
          run_root = abs_path(resources.fetch('cgroup_root'))
          next unless descendant?(run_root, root)

          generations << { root: run_root, role: }

          CGROUP_RESOURCE_KEYS.each do |key|
            path = resources[key]
            next unless path

            absolute = abs_path(path)
            next unless descendant?(absolute, root)

            if key == 'lxc_payload'
              managed[absolute] = role
              @active_payload_owners[absolute] = container if role == :active
            end
          end
        end
      end

      [managed, generations]
    end

    def target_state(entries)
      stable = entries.detect { |entry| entry.path == root }
      raise Error, "group CPU cgroup #{root} is missing" unless stable

      request = requested_state(
        anchor.cgparams,
        stable.current,
        resets: @reset_parameters
      )
      parent = effective_state(File.dirname(root))
      cap_request(request, parent)
    end

    def desired_states(entries, _target)
      requests = local_requests(entries)
      effective = {}

      entries.to_h do |entry|
        ancestor =
          if entry.path == root
            effective_state(File.dirname(root))
          else
            entries
              .take_while { |candidate| candidate.depth < entry.depth }
              .reverse_each
              .detect { |candidate| descendant?(entry.path, candidate.path) }
              .then { |candidate| candidate && effective.fetch(candidate.path) }
          end

        request = requests[entry.path]
        desired =
          if request
            if CGroup.v1? \
                && @configured_requests.include?(entry.path) \
                && ancestor \
                && !request.unlimited? \
                && compare(request, ancestor) > 0
              raise Error,
                    "configured CPU bandwidth #{format_state(request)} at " \
                    "#{entry.path} exceeds prospective parent bandwidth " \
                    "#{format_state(ancestor)}"
            end
            cap_request(request, ancestor)
          elsif entry.current.unlimited?
            copy_state(entry.current)
          else
            cap_request(entry.current, ancestor)
          end
        if entry.generation_role == :residual
          desired =
            if entry.path == entry.generation_root
              narrower(entry.effective, desired)
            else
              unlimited_state(entry.current)
            end
        end
        effective[entry.path] =
          if ancestor
            narrower(desired, ancestor)
          else
            copy_state(desired)
          end

        [entry.path, desired]
      end
    end

    def local_requests(entries)
      current = entries.to_h { |entry| [entry.path, entry.current] }
      requests = {}
      @configured_requests = []

      groups.each do |group|
        path = abs_path(group.cgroup_path)
        state = current[path]
        if !state && group == anchor
          raise Error, "configured group CPU cgroup #{path} is missing"
        end
        next unless state

        requests[path] = requested_state(
          group.cgparams,
          state,
          resets: group == anchor ? @reset_parameters : []
        )
        @configured_requests << path \
          if cpu_bandwidth_configured?(group.cgparams)
      end

      @stable_owners.each do |path, container|
        state = current[path]
        next unless state

        request = requested_state(container.cgparams, state)
        requests[path] = request
        @configured_requests << path \
          if cpu_bandwidth_configured?(container.cgparams)
      end

      @active_payload_owners.each_key do |path|
        state = current[path]
        next unless state

        requests[path] = unlimited_state(state)
      end

      requests
    end

    def requested_state(cgparams, current, resets: [])
      configured = configured_params(cgparams)

      if CGroup.v2?
        return State.new(quota: -1, period: current.period) \
          if configured.empty?

        configured_v2_state(current, configured)
      else
        quota = configured_value(QUOTA_PARAMETER, configured)
        period = configured_value(PERIOD_PARAMETER, configured)
        State.new(
          quota:
            if quota.nil?
              if configured.empty? || resets.include?(QUOTA_PARAMETER)
                -1
              else
                current.quota
              end
            else
              quota
            end,
          period:
            if period.nil?
              if configured.empty? || resets.include?(PERIOD_PARAMETER)
                100_000
              else
                current.period
              end
            else
              period
            end
        )
      end
    end

    def configured_params(cgparams)
      cgparams.each.select do |param|
        param.version == CGroup.version \
          && PARAMETERS.include?(param.name)
      end
    end

    def cpu_bandwidth_configured?(cgparams)
      configured_params(cgparams).any?
    end

    def preflight_existing_topology!
      return unless File.exist?(parameter_path(root))

      entries = scan_entries
      target = target_state(entries)
      validate_target!(target)
      desired = desired_states(entries, target)
      build_plan(entries, desired)
    end

    def validate_configured_hierarchy!
      nodes = groups.map do |group|
        [abs_path(group.cgroup_path), group.cgparams]
      end
      nodes.concat(
        containers.map do |container|
          [abs_path(container.base_cgroup_path), container.cgparams]
        end
      )
      effective = {}
      external = effective_state(File.dirname(root))

      nodes.sort_by { |path, _cgparams| [relative_depth(path), path] }
           .each do |path, cgparams|
        ancestor =
          effective
          .select { |candidate, _state| descendant?(path, candidate) }
          .max_by { |candidate, _state| candidate.length }
          &.last || external
        configured = configured_params(cgparams)
        current =
          if File.exist?(parameter_path(path))
            read_state(path)
          else
            State.new(quota: -1, period: 100_000)
          end
        request =
          if configured.empty?
            State.new(quota: -1, period: 100_000)
          else
            requested_state(
              cgparams,
              current,
              resets: path == root ? @reset_parameters : []
            )
          end
        validate_state!(request, path)
        if CGroup.v1? \
            && configured.any? \
            && ancestor \
            && !request.unlimited? \
            && compare(request, ancestor) > 0
          raise Error,
                "configured CPU bandwidth #{format_state(request)} at " \
                "#{path} exceeds prospective parent bandwidth " \
                "#{format_state(ancestor)}"
        end

        effective[path] =
          ancestor ? narrower(request, ancestor) : copy_state(request)
      end
    end

    def cap_request(request, ancestor)
      return copy_state(request) unless ancestor
      return copy_state(request) if request.unlimited?
      return copy_state(request) if CGroup.v2?

      narrower(request, ancestor)
    end
  end
end
