require 'libosctl/cpu_mask'
require 'osctld/cgroup'

module OsCtld
  # Applies a CPU mask to every live cgroup below the stable container policy
  # root.
  #
  # Cgroup v1 rejects a parent mask which excludes CPUs still configured on a
  # child. Cgroup v2 permits inherited masks, but an empty namespaced root does
  # not expose the configured policy through cpuset.cpus. Updating only
  # ct.<id>, the LXC payload, or payload/inner is therefore insufficient.
  class CGroup::CpusetPolicy
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

    Entry = Struct.new(
      :path,
      :depth,
      :explicit,
      :effective,
      :roles,
      :inner,
      :generation_role,
      keyword_init: true
    )
    Result = Struct.new(
      :target,
      :run_masks,
      keyword_init: true
    )

    class Error < StandardError
      attr_reader :cleanup_params, :policy_compensated, :rollback_error

      def initialize(
        message,
        rollback_error: nil,
        cleanup_params: [],
        policy_compensated: false
      )
        super(message)
        @rollback_error = rollback_error
        @cleanup_params = cleanup_params
        @policy_compensated = policy_compensated
      end
    end

    # @param ct [Container]
    # @param target [String] Linux CPU-list syntax
    def initialize(ct, target)
      @ct = ct
      @target = normalize_mask(parse_mask(target))
    end

    # Restricting a hierarchy is committed from leaves to root. Expanding it
    # is prepared from root to leaves. A disjoint change combines both phases:
    # expand every node to current U target, then commit target leaf-first.
    #
    # @return [Result]
    def apply
      CGroup.sync do
        entries = scan_entries
        originals = entries.to_h { |entry| [entry.path, entry.dup] }
        validate_target!(entries)
        desired = desired_masks(entries)

        begin
          apply_masks(entries, desired)
          verify!(desired)
          result = Result.new(
            target:,
            run_masks: generation_masks
          )
        rescue StandardError => e
          rollback_error = rollback(originals)
          message = "unable to apply cpuset policy: #{e.message}"
          if rollback_error
            message = "#{message}; rollback failed: #{rollback_error.message}"
          end
          raise Error.new(message, rollback_error:)
        end

        result
      end
    end

    # Return the mask inherited by the stable container cgroup.
    #
    # @param ct [Container]
    # @return [String]
    def self.parent_mask(ct)
      root = CGroup.abs_cgroup_path('cpuset', ct.base_cgroup_path)
      read_effective_mask(File.dirname(root))
    end

    def self.read_effective_mask(path)
      effective_file = false
      %w[cpuset.cpus.effective cpuset.effective_cpus].each do |name|
        file = File.join(path, name)
        next unless File.exist?(file)

        effective_file = true
        value = File.read(file).strip
        return normalize_mask(parse_mask(value)) unless value.empty?
      end

      if effective_file
        raise Error, "cpuset effective mask is empty at #{path}"
      end

      explicit = File.read(File.join(path, 'cpuset.cpus')).strip
      return normalize_mask(parse_mask(explicit)) unless explicit.empty?

      raise Error, "cpuset effective mask is unavailable at #{path}"
    end

    class << self
      protected

      def parse_mask(value)
        str = value.to_s
        raise Error, 'cpuset mask is empty' if str.empty?

        cpus = str.split(',').flat_map do |part|
          case part
          when /\A[0-9]+\z/
            [Integer(part, 10)]
          when /\A([0-9]+)-([0-9]+)\z/
            first = Integer(Regexp.last_match(1), 10)
            last = Integer(Regexp.last_match(2), 10)
            raise Error, "invalid cpu range #{part.inspect}" if first > last

            (first..last).to_a
          else
            raise Error, "invalid cpuset mask #{str.inspect}"
          end
        end

        cpus.uniq.sort
      end

      def normalize_mask(cpus)
        raise Error, 'cpuset mask is empty' if cpus.empty?

        OsCtl::Lib::CpuMask.format(cpus.uniq.sort)
      end
    end

    protected

    attr_reader :ct, :target

    def scan_entries
      root = cgroup_root
      parameter = File.join(root, 'cpuset.cpus')
      unless File.exist?(parameter)
        raise Error, "cpuset cgroup does not exist at #{root}"
      end

      known, inner_paths, generations = topology_metadata
      paths = [root]
      paths.concat(
        Dir.glob(File.join(root, '**', 'cpuset.cpus')).map { |v| File.dirname(v) }
      )

      paths.uniq.map do |path|
        explicit = File.read(File.join(path, 'cpuset.cpus')).strip
        roles = known.fetch(path, [])
        generation = generations
                     .select { |item| descendant?(path, item.fetch(:root)) }
                     .max_by { |item| item.fetch(:root).length }

        Entry.new(
          path:,
          depth: relative_depth(path),
          explicit:,
          effective: read_effective_mask(path),
          roles:,
          inner: inner_paths.include?(path),
          generation_role: generation && generation.fetch(:role)
        )
      end.sort_by { |entry| [entry.depth, entry.path] }
    rescue Errno::ENOENT => e
      raise Error, "cgroup topology changed while scanning: #{e.message}"
    end

    def topology_metadata
      known = Hash.new { |hash, key| hash[key] = [] }
      inner_paths = []
      generations = []
      add_known_path(known, ct.base_cgroup_path, :stable)

      ct.lifecycle.runs.each_value do |run|
        role = run.fetch('role').to_sym
        next unless %i[active residual].include?(role)

        resources = run.fetch('resources')
        root = resources.fetch('cgroup_root')
        generations << { root: abs_path(root), role: }

        CGROUP_RESOURCE_KEYS.each do |key|
          path = resources[key]
          next unless path

          add_known_path(known, path, role)
          inner_paths << abs_path(path) if key == 'lxc_inner'
        end
      end

      [known, inner_paths.uniq, generations]
    end

    def add_known_path(known, relative_path, role)
      root = cgroup_root
      path = abs_path(relative_path)
      return unless descendant?(path, root)

      loop do
        known[path] << role unless known[path].include?(role)
        break if path == root

        path = File.dirname(path)
      end
    end

    def desired_masks(entries)
      wanted = parse_mask(target)

      entries.to_h do |entry|
        desired =
          if entry.path == cgroup_root || entry.roles.include?(:active)
            target
          elsif entry.generation_role == :residual \
              || entry.roles.include?(:residual)
            residual_mask(entry, wanted)
          elsif entry.generation_role == :active
            descendant_mask(entry, wanted, inherit: true)
          else
            descendant_mask(entry, wanted, inherit: false)
          end

        [entry.path, desired]
      end
    end

    def residual_mask(entry, wanted)
      current = entry.effective
      selected =
        if subset?(wanted, current)
          wanted
        elsif subset?(current, wanted)
          current
        else
          current & wanted
        end

      normalize_mask(selected)
    rescue Error
      raise Error,
            "residual cgroup #{entry.path} cannot be restricted from " \
            "#{normalize_mask(current)} to #{target}"
    end

    def descendant_mask(entry, wanted, inherit:)
      if entry.explicit.empty?
        return if inherit

        return normalize_mask(entry.effective & wanted)
      end

      current = parse_mask(entry.explicit)
      return normalize_mask(current) if subset?(current, wanted)

      normalize_mask(current & wanted)
    rescue Error
      raise Error,
            "cgroup #{entry.path} cannot be restricted from " \
            "#{normalize_mask(configured_or_effective(entry))} to #{target}"
    end

    def apply_masks(entries, desired)
      # Pin every residual request to its pre-transaction effective grant
      # before expanding a parent. An inherited request is not the only case
      # which can broaden: a non-empty request can be wider than the current
      # grant because an ancestor is narrower.
      entries.each do |entry|
        next unless entry.generation_role == :residual

        effective = normalize_mask(entry.effective)
        next if normalize_optional(entry.explicit) == effective

        write_mask(entry, effective)
      end

      # Make every parent large enough for both its current and final
      # descendants.
      entries.each do |entry|
        final = desired[entry.path]
        next unless final

        union = entry.effective | parse_mask(final)
        write_mask(entry, normalize_mask(union))
      end

      # Commit the final policy from leaves to root. This is the order required
      # to narrow cpuset hierarchies on cgroup v1.
      entries.reverse_each do |entry|
        final = desired[entry.path]
        next unless final

        write_mask(
          entry,
          final,
          force: entry.inner && entry.roles.include?(:active)
        )
      end
    end

    def verify!(desired)
      entries = scan_entries
      actual_paths = entries.map(&:path)
      missing = desired.keys - actual_paths
      unless missing.empty?
        raise Error, "cgroup paths disappeared: #{missing.join(', ')}"
      end

      allowed = parse_mask(target)
      entries.each do |entry|
        unless subset?(entry.effective, allowed)
          raise Error,
                "#{entry.path} has effective mask " \
                "#{normalize_mask(entry.effective)}, outside #{target}"
        end

        wanted = desired[entry.path]
        effective_wanted =
          wanted || (entry.generation_role == :active ? target : nil)
        if effective_wanted \
            && entry.effective != parse_mask(effective_wanted)
          raise Error,
                "#{entry.path} has effective mask " \
                "#{normalize_mask(entry.effective)}, " \
                "expected #{effective_wanted}"
        end

        next unless wanted
        next if normalize_optional(entry.explicit) == wanted

        raise Error,
              "#{entry.path} has configured mask #{entry.explicit.inspect}, " \
              "expected #{wanted}"
      end
    end

    def rollback(originals)
      current = originals.values.filter_map do |original|
        next unless File.exist?(File.join(original.path, 'cpuset.cpus'))

        Entry.new(
          path: original.path,
          depth: original.depth,
          explicit: File.read(File.join(original.path, 'cpuset.cpus')).strip,
          effective: read_effective_mask(original.path)
        )
      end.sort_by { |entry| [entry.depth, entry.path] }
      missing = originals.keys - current.map(&:path)
      unless missing.empty?
        return Error.new("cgroup paths disappeared: #{missing.join(', ')}")
      end

      # Preserve every residual's current grant while ancestors are prepared
      # to reach the original masks. This is necessary even when cpuset.cpus
      # is non-empty, because it can be wider than the effective grant.
      current.each do |entry|
        original = originals.fetch(entry.path)
        next unless original.generation_role == :residual

        effective = normalize_mask(entry.effective)
        next if normalize_optional(entry.explicit) == effective

        write_mask(entry, effective)
      end

      # Make the old grants reachable. Residuals are restored only as far as
      # their pre-transaction effective grants, never to a broader request.
      current.each do |entry|
        original = originals.fetch(entry.path)
        union =
          if original.generation_role == :residual
            original.effective
          else
            entry.effective | original.effective
          end
        write_mask(entry, normalize_mask(union))
      end

      # Restore safe requests leaf-first. This also puts the original ancestor
      # caps back before broader residual requests are restored.
      current.reverse_each do |entry|
        original = originals.fetch(entry.path)
        next if original.explicit.empty?
        next if residual_request_wider_than_grant?(original)

        write_mask(entry, original.explicit)
      end

      # A broad residual request is safe only after its original ancestor caps
      # have been restored. Expand these requests root-first.
      current.each do |entry|
        original = originals.fetch(entry.path)
        next unless residual_request_wider_than_grant?(original)

        write_mask(entry, original.explicit)
      end

      # Clear inherited requests last, once their parents again have the
      # original configured masks.
      current.each do |entry|
        original = originals.fetch(entry.path)
        next unless original.explicit.empty?

        write_mask(entry, '')
      end

      nil
    rescue StandardError => e
      e
    end

    def residual_request_wider_than_grant?(entry)
      entry.generation_role == :residual \
        && !entry.explicit.empty? \
        && !subset?(parse_mask(entry.explicit), entry.effective)
    end

    def generation_masks
      ct.lifecycle.runs.each_with_object({}) do |(run_key, run), ret|
        next unless %w[active residual].include?(run.fetch('role'))

        root = abs_path(run.fetch('resources').fetch('cgroup_root'))
        next unless File.exist?(File.join(root, 'cpuset.cpus'))

        ret[run_key] = normalize_mask(read_effective_mask(root))
      end
    end

    def validate_target!(entries)
      parent_mask = read_effective_mask(File.dirname(cgroup_root))
      wanted = parse_mask(target)
      unless subset?(wanted, parent_mask)
        raise Error,
              "cpuset mask #{target} exceeds parent mask " \
              "#{normalize_mask(parent_mask)}"
      end

      root = entries.detect { |entry| entry.path == cgroup_root }
      raise Error, "stable cgroup #{cgroup_root} is missing" unless root
    end

    def set_mask(path, mask)
      parameter = File.join(path, 'cpuset.cpus')
      value = mask.empty? ? "\n" : mask
      return if CGroup.set_param(parameter, [value])

      raise Error, "kernel rejected cpuset mask #{mask.inspect} at #{path}"
    end

    def write_mask(entry, wanted, force: false)
      return if !force && normalize_optional(entry.explicit) == wanted

      set_mask(entry.path, wanted)
      entry.explicit = wanted
      entry.effective = wanted.empty? ? read_effective_mask(entry.path) : parse_mask(wanted)
    end

    def configured_or_effective(entry)
      entry.explicit.empty? ? entry.effective : parse_mask(entry.explicit)
    end

    def read_effective_mask(path)
      parse_mask(self.class.read_effective_mask(path))
    end

    def parse_mask(value)
      self.class.send(:parse_mask, value)
    end

    def normalize_mask(cpus)
      self.class.send(:normalize_mask, cpus)
    end

    def normalize_optional(value)
      return if value.nil? || value.empty?

      normalize_mask(parse_mask(value))
    end

    def subset?(left, right)
      (left - right).empty?
    end

    def cgroup_root
      @cgroup_root ||= abs_path(ct.base_cgroup_path)
    end

    def abs_path(path)
      File.expand_path(CGroup.abs_cgroup_path('cpuset', path))
    end

    def descendant?(path, root)
      path == root || path.start_with?("#{root}/")
    end

    def relative_depth(path)
      return 0 if path == cgroup_root

      path.delete_prefix("#{cgroup_root}/").split('/').length
    end
  end
end
