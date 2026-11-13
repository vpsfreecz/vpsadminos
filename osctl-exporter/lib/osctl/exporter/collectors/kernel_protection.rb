require 'json'
require 'open3'
require 'osctl/exporter/collectors/base'

module OsCtl::Exporter
  class Collectors::KernelProtection < Collectors::Base
    EBPF_CONFIG_PATH = '/etc/vpsadminos/ebpf-livepatch-monitor.json'.freeze
    LIVEPATCH_CONFIG_PATH = '/etc/vpsadminos/livepatch-monitor.json'.freeze
    BOOTED_LIVEPATCH_CONFIG_PATH = '/run/booted-system/etc/vpsadminos/livepatch-monitor.json'.freeze
    KERNEL_NOTES_PATH = '/sys/kernel/notes'.freeze
    BOOTED_KERNEL_IMAGE_PATH = '/run/booted-system/kernel'.freeze
    LIVEPATCH_SYSFS = '/sys/kernel/livepatch'.freeze

    class ProbeError < StandardError; end

    def setup
      add_metric(
        :bpf_program_required,
        :gauge,
        :kernel_bpf_program_required,
        docstring: 'Required vpsAdminOS BPF livepatch program',
        labels: %i[program since_kernel until_kernel]
      )
      add_metric(
        :bpf_program_loaded,
        :gauge,
        :kernel_bpf_program_loaded,
        docstring: 'Whether all expected kernel BPF programs are attached',
        labels: %i[program since_kernel until_kernel]
      )
      add_metric(
        :livepatch_required,
        :gauge,
        :kernel_livepatch_required,
        docstring: 'Required vpsAdminOS kernel livepatch module',
        labels: %i[module patch_version]
      )
      add_metric(
        :livepatch_loaded,
        :gauge,
        :kernel_livepatch_loaded,
        docstring: 'Whether the kernel livepatch module is enabled and stable',
        labels: %i[module patch_version]
      )
      add_metric(
        :livepatch_transition,
        :gauge,
        :kernel_livepatch_transition,
        docstring: 'Whether the kernel livepatch module is transitioning',
        labels: %i[module patch_version]
      )
      add_metric(
        :monitoring_success,
        :gauge,
        :kernel_protection_monitoring_success,
        docstring: 'Whether vpsAdminOS kernel protection monitoring succeeded',
        labels: %i[component]
      )
    end

    def collect(_client)
      collect_bpf
      collect_livepatch
    end

    protected

    def collect_bpf
      cfg = read_json_config(EBPF_CONFIG_PATH, 'bpf')
      return if cfg.nil?

      programs = Array(cfg['programs'])
      programs.each do |program|
        @bpf_program_required.set(1, labels: bpf_program_labels(program))
      end

      loaded_bpf_names = []
      success = 1

      begin
        loaded_bpf_names = loaded_bpf_program_names(cfg.fetch('bpftool'))
      rescue KeyError, ProbeError
        success = 0
      end

      programs.each do |program|
        labels = bpf_program_labels(program)
        required_bpf_names = Array(program['bpfPrograms'])
        loaded =
          !required_bpf_names.empty? && required_bpf_names.all? do |name|
            loaded_bpf_names.include?(name)
          end

        @bpf_program_loaded.set(loaded ? 1 : 0, labels:)
      end

      @monitoring_success.set(success, labels: { component: 'bpf' })
    rescue StandardError
      @monitoring_success.set(0, labels: { component: 'bpf' })
    end

    def collect_livepatch
      cfg = read_livepatch_config(LIVEPATCH_CONFIG_PATH)
      return if cfg.nil?

      metadata_success = true
      entries = []

      begin
        unless livepatch_kernel_matches?(cfg)
          # An OS switch does not replace the running kernel. The booted
          # generation retains its matching livepatch requirements and module.
          cfg = read_livepatch_config(BOOTED_LIVEPATCH_CONFIG_PATH)
          unless cfg && livepatch_kernel_matches?(cfg)
            raise ProbeError, 'Missing matching booted livepatch configuration'
          end
        end

        entries = livepatch_entries(cfg)
      rescue StandardError
        metadata_success = false
      end

      entries.each do |entry|
        @livepatch_required.set(1, labels: livepatch_labels(entry))
      end

      labels_by_module = entries.to_h do |entry|
        [entry.fetch('module'), livepatch_labels(entry)]
      end
      states, sysfs_readable, sysfs_success = livepatch_states

      if sysfs_readable
        (labels_by_module.keys | states.keys).sort.each do |mod|
          labels = labels_by_module.fetch(mod, { module: mod, patch_version: '' })
          state = states[mod]
          next if states.has_key?(mod) && state.nil?

          state ||= { enabled: false, transition: false }
          @livepatch_loaded.set(state[:enabled] && !state[:transition] ? 1 : 0, labels:)
          @livepatch_transition.set(state[:transition] ? 1 : 0, labels:)
        end
      end

      success = metadata_success && sysfs_success
      @monitoring_success.set(success ? 1 : 0, labels: { component: 'livepatch' })
    rescue StandardError
      @monitoring_success.set(0, labels: { component: 'livepatch' })
    end

    def read_livepatch_config(path)
      return unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError, SystemCallError => e
      raise ProbeError, e.message
    end

    def read_json_config(path, component)
      return unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError, SystemCallError
      @monitoring_success.set(0, labels: { component: })
      nil
    end

    def livepatch_kernel_matches?(cfg)
      if cfg.has_key?('kernelImage') && File.realpath(BOOTED_KERNEL_IMAGE_PATH) != cfg.fetch('kernelImage')
        return false
      end

      # Older generations did not record the build notes. Preserve their
      # schema, including when reached through the host-owned booted symlink.
      return true unless cfg.has_key?('kernelNotes')

      expected = File.binread(cfg.fetch('kernelNotes'))
      !expected.empty? && expected == File.binread(KERNEL_NOTES_PATH)
    end

    def livepatch_entries(cfg)
      entries =
        if cfg.has_key?('modules')
          unless cfg['schemaVersion'].is_a?(Integer) && cfg['schemaVersion'] == 2
            raise ProbeError, 'Unsupported livepatch monitor schema'
          end
          unless cfg['modules'].is_a?(Array) && !cfg['modules'].empty?
            raise ProbeError, 'Invalid livepatch module list'
          end

          cfg['modules'].each do |entry|
            unless entry.is_a?(Hash) && entry['patches'].is_a?(Array)
              raise ProbeError, 'Invalid livepatch module entry'
            end
          end
        else
          [cfg]
        end

      modules = entries.map do |entry|
        raise ProbeError, 'Invalid livepatch module entry' unless entry.is_a?(Hash)

        mod = entry.fetch('module')
        patch_version = entry.fetch('patchVersion')
        unless mod.is_a?(String) && !mod.empty? && patch_version.is_a?(Integer) && patch_version > 0
          raise ProbeError, 'Invalid livepatch module identity'
        end

        mod
      end

      raise ProbeError, 'Duplicate livepatch module' unless modules.uniq.length == modules.length

      entries
    rescue KeyError => e
      raise ProbeError, e.message
    end

    def livepatch_labels(entry)
      {
        module: entry.fetch('module'),
        patch_version: entry.fetch('patchVersion').to_s
      }
    end

    def bpf_program_labels(program)
      {
        program: program.fetch('name'),
        since_kernel: program.fetch('sinceKernel'),
        until_kernel: program['untilKernel'] || ''
      }
    end

    def loaded_bpf_program_names(bpftool)
      programs = bpftool_json(bpftool, 'prog', 'show')
      links = bpftool_json(bpftool, 'link', 'show')
      linked_program_ids = links.filter_map { |link| link_program_id(link) }.map(&:to_i)

      programs.filter_map do |program|
        program['name'] if linked_program_ids.include?(program['id'].to_i)
      end
    end

    def link_program_id(link)
      link['prog_id'] || link.dig('prog', 'id')
    end

    def bpftool_json(bpftool, *args)
      stdout, stderr, status = Open3.capture3(bpftool, '-j', *args)

      unless status.success?
        raise ProbeError, "bpftool #{args.join(' ')} failed: #{stderr.strip}"
      end

      JSON.parse(stdout)
    rescue Errno::ENOENT, JSON::ParserError => e
      raise ProbeError, e.message
    end

    def livepatch_states
      return [{}, true, true] unless Dir.exist?(LIVEPATCH_SYSFS)

      success = true
      states = Dir.children(LIVEPATCH_SYSFS).sort.each_with_object({}) do |entry, ret|
        mod_dir = File.join(LIVEPATCH_SYSFS, entry)
        next unless File.directory?(mod_dir)

        begin
          enabled = read_boolean_sysfs(File.join(mod_dir, 'enabled'))
          transition = read_boolean_sysfs(File.join(mod_dir, 'transition'))
          ret[entry] = { enabled:, transition: }
        rescue ProbeError
          success = false
          ret[entry] = nil
        end
      end

      [states, true, success]
    rescue SystemCallError
      [{}, false, false]
    end

    def read_boolean_sysfs(path)
      value = File.read(path).strip
      raise ProbeError, "Invalid boolean value in #{path}" unless %w[0 1].include?(value)

      value == '1'
    rescue SystemCallError => e
      raise ProbeError, e.message
    end
  end
end
