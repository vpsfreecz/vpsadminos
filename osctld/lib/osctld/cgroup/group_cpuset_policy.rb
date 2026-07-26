require 'osctld/cgroup/cpuset_policy'

module OsCtld
  # Reconstructs configured group cpusets as one hierarchy transaction.
  #
  # Cgroup v1 children inherit the host mask when their paths are recreated.
  # Applying a narrower parent before its children then fails with EBUSY. This
  # policy pins the current grants, prepares unions root-first and commits the
  # configured hierarchy leaf-first. All cgroups below the first configured
  # group are included so user and stopped-container paths cannot retain a
  # mask wider than their group.
  class CGroup::GroupCpusetPolicy
    Result = Struct.new(:rollback_proc, keyword_init: true) do
      def rollback!
        return true unless rollback_proc

        error = rollback_proc.call
        raise error if error

        self.rollback_proc = nil
        true
      end
    end

    Entry = Struct.new(
      :path,
      :depth,
      :explicit,
      :effective,
      :boundary,
      keyword_init: true
    )

    def initialize(anchor, reconstruct_to: nil)
      @anchor = anchor
      @groups = [anchor, *anchor.descendants]
      @reconstruct_group = validate_reconstruct_group(reconstruct_to)
      @targets = configured_targets
      raise CGroup::CpusetPolicy::Error, 'group has no configured cpuset' \
        unless @targets.has_key?(abs_path(anchor.cgroup_path))

      validate_targets!
    end

    def applied?
      if @reconstruct_group \
          && !File.exist?(
            File.join(abs_path(@reconstruct_group.cgroup_path), 'cpuset.cpus')
          )
        return false
      end

      entries = scan_entries
      return false unless entries

      desired = desired_masks(entries)
      entries.all? do |entry|
        wanted = desired[entry.path]
        next false if wanted && normalize_optional(entry.explicit) != wanted

        subset?(entry.effective, parse_mask(entry.boundary))
      end
    end

    def apply
      originals = nil
      preparation_started = false

      CGroup.sync do
        preparation_started = true
        ensure_paths
        entries = scan_entries
        unless entries
          raise CGroup::CpusetPolicy::Error,
                "group cpuset hierarchy is missing below #{root}"
        end

        originals = entries.to_h { |entry| [entry.path, entry.dup] }
        desired = desired_masks(entries)
        apply_masks(entries, desired)
        verify!
      rescue StandardError => e
        rollback_error = originals && rollback(originals)
        rollback_error ||= preparation_rollback_error \
          if preparation_started
        message = "unable to apply group cpuset policy: #{e.message}"
        if rollback_error
          message = "#{message}; rollback failed: #{rollback_error.message}"
        end
        raise CGroup::CpusetPolicy::Error.new(
          message,
          rollback_error:
        )
      end

      preparation_error =
        preparation_started ? preparation_rollback_error : nil
      Result.new(
        rollback_proc: proc do
          CGroup.sync do
            rollback(originals) || preparation_error
          end
        end
      )
    end

    protected

    attr_reader :anchor, :groups, :targets

    def configured_targets
      groups.each_with_object({}) do |group, ret|
        param = group.cgparams.detect do |candidate|
          candidate.version == CGroup.version \
            && candidate.name == 'cpuset.cpus'
        end
        next unless param

        ret[abs_path(group.cgroup_path)] = normalize(param.value.last)
      end
    end

    def validate_targets!
      targets.each do |path, target|
        parent = nearest_boundary(File.dirname(path))
        parent_mask =
          if parent
            targets.fetch(parent)
          else
            CGroup::CpusetPolicy.read_effective_mask(File.dirname(path))
          end
        next if subset?(parse_mask(target), parse_mask(parent_mask))

        raise CGroup::CpusetPolicy::Error,
              "group cpuset #{target} at #{path} exceeds parent " \
              "mask #{parent_mask}"
      end
    end

    def ensure_paths
      return unless @reconstruct_group

      CGroup.mkpath(
        'cpuset',
        @reconstruct_group.cgroup_path.split('/'),
        leaf: false
      )
    end

    def preparation_rollback_error
      return unless @reconstruct_group

      CGroup::CpusetPolicy::Error.new(
        'requested cpuset cgroup path/controller reconstruction cannot be ' \
        'rolled back exactly'
      )
    end

    def validate_reconstruct_group(group)
      return unless group

      unless groups.include?(group)
        raise CGroup::CpusetPolicy::Error,
              'cpuset reconstruction target is outside its group subtree'
      end

      group
    end

    def scan_entries
      return unless File.exist?(File.join(root, 'cpuset.cpus'))

      paths = [root]
      paths.concat(
        Dir.glob(File.join(root, '**', 'cpuset.cpus')).map do |file|
          File.dirname(file)
        end
      )

      paths.uniq.map do |path|
        boundary = nearest_boundary(path)
        next unless boundary

        Entry.new(
          path:,
          depth: relative_depth(path),
          explicit: File.read(File.join(path, 'cpuset.cpus')).strip,
          effective: read_effective(path),
          boundary: targets.fetch(boundary)
        )
      end.compact.sort_by { |entry| [entry.depth, entry.path] }
    rescue Errno::ENOENT => e
      raise CGroup::CpusetPolicy::Error,
            "group cgroup topology changed while scanning: #{e.message}"
    end

    def desired_masks(entries)
      entries.to_h do |entry|
        if CGroup.v2? && !targets.has_key?(entry.path)
          next [entry.path, nil]
        end

        allowed = parse_mask(entry.boundary)
        desired =
          if targets.has_key?(entry.path)
            entry.boundary
          else
            selected = entry.effective & allowed
            if selected.empty?
              raise CGroup::CpusetPolicy::Error,
                    "cgroup #{entry.path} has mask " \
                    "#{normalize_mask(entry.effective)} disjoint from " \
                    "group policy #{entry.boundary}"
            end
            normalize_mask(selected)
          end

        [entry.path, desired]
      end
    end

    def apply_masks(entries, desired)
      unless CGroup.v2?
        entries.each do |entry|
          effective = normalize_mask(entry.effective)
          next if normalize_optional(entry.explicit) == effective

          write_mask(entry, effective)
        end
      end

      entries.each do |entry|
        wanted = desired[entry.path]
        next unless wanted

        union = entry.effective | parse_mask(wanted)
        write_mask(entry, normalize_mask(union))
      end

      entries.reverse_each do |entry|
        wanted = desired[entry.path]
        write_mask(entry, wanted) if wanted
      end
    end

    def verify!
      entries = scan_entries
      unless entries
        raise CGroup::CpusetPolicy::Error,
              "group cpuset hierarchy disappeared below #{root}"
      end

      desired = desired_masks(entries)
      entries.each do |entry|
        allowed = parse_mask(entry.boundary)
        unless subset?(entry.effective, allowed)
          raise CGroup::CpusetPolicy::Error,
                "#{entry.path} has effective mask " \
                "#{normalize_mask(entry.effective)}, outside " \
                "#{entry.boundary}"
        end

        wanted = desired[entry.path]
        next unless wanted
        next if normalize_optional(entry.explicit) == wanted \
          && entry.effective == parse_mask(wanted)

        raise CGroup::CpusetPolicy::Error,
              "#{entry.path} did not reach group cpuset #{wanted}"
      end
    end

    def rollback(originals)
      current = originals.values.filter_map do |original|
        next unless File.exist?(File.join(original.path, 'cpuset.cpus'))

        Entry.new(
          path: original.path,
          depth: original.depth,
          explicit: File.read(
            File.join(original.path, 'cpuset.cpus')
          ).strip,
          effective: read_effective(original.path),
          boundary: original.boundary
        )
      end.sort_by { |entry| [entry.depth, entry.path] }
      missing = originals.keys - current.map(&:path)
      unless missing.empty?
        return CGroup::CpusetPolicy::Error.new(
          "cgroup paths disappeared: #{missing.join(', ')}"
        )
      end

      current.each do |entry|
        original = originals.fetch(entry.path)
        union = entry.effective | original.effective
        write_mask(entry, normalize_mask(union))
      end

      current.reverse_each do |entry|
        original = originals.fetch(entry.path)
        next if original.explicit.empty?

        write_mask(entry, original.explicit)
      end

      current.each do |entry|
        original = originals.fetch(entry.path)
        write_mask(entry, '') if original.explicit.empty?
      end

      nil
    rescue StandardError => e
      e
    end

    def write_mask(entry, mask)
      return if normalize_optional(entry.explicit) == normalize_optional(mask)

      path = File.join(entry.path, 'cpuset.cpus')
      value = mask.empty? ? "\n" : mask
      unless CGroup.set_param(path, [value])
        raise CGroup::CpusetPolicy::Error,
              "kernel rejected cpuset mask #{mask.inspect} at #{entry.path}"
      end

      entry.explicit = mask
      entry.effective =
        if mask.empty?
          read_effective(entry.path)
        else
          parse_mask(mask)
        end
    end

    def nearest_boundary(path)
      targets.keys
             .select { |candidate| descendant?(path, candidate) }
             .max_by(&:length)
    end

    def read_effective(path)
      parse_mask(CGroup::CpusetPolicy.read_effective_mask(path))
    end

    def normalize(value)
      normalize_mask(parse_mask(value))
    end

    def parse_mask(value)
      CGroup::CpusetPolicy.send(:parse_mask, value)
    end

    def normalize_mask(value)
      CGroup::CpusetPolicy.send(:normalize_mask, value)
    end

    def normalize_optional(value)
      return if value.nil? || value.empty?

      normalize(value)
    end

    def subset?(left, right)
      (left - right).empty?
    end

    def abs_path(path)
      File.expand_path(CGroup.abs_cgroup_path('cpuset', path))
    end

    def root
      @root ||= abs_path(anchor.cgroup_path)
    end

    def descendant?(path, parent)
      path == parent || path.start_with?("#{parent}/")
    end

    def relative_depth(path)
      return 0 if path == root

      path.delete_prefix("#{root}/").split('/').length
    end
  end
end
