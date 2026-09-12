require 'json'
require 'open3'
require 'osctl/exporter/collectors/base'

module OsCtl::Exporter
  class Collectors::KernelProtection < Collectors::Base
    EBPF_CONFIG_PATH = '/etc/vpsadminos/ebpf-livepatch-monitor.json'.freeze
    LIVEPATCH_CONFIG_PATH = '/etc/vpsadminos/livepatch-monitor.json'.freeze
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
        docstring: 'Whether the required kernel livepatch module is enabled',
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
      cfg = read_json_config(LIVEPATCH_CONFIG_PATH, 'livepatch')
      return if cfg.nil?

      labels = {
        module: cfg.fetch('module'),
        patch_version: cfg.fetch('patchVersion').to_s
      }

      @livepatch_required.set(1, labels:)
      @livepatch_loaded.set(livepatch_loaded?(cfg.fetch('module')) ? 1 : 0, labels:)
      @monitoring_success.set(1, labels: { component: 'livepatch' })
    rescue StandardError
      @monitoring_success.set(0, labels: { component: 'livepatch' })
    end

    def read_json_config(path, component)
      return unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError, SystemCallError
      @monitoring_success.set(0, labels: { component: })
      nil
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

    def livepatch_loaded?(mod)
      mod_dir = File.join(LIVEPATCH_SYSFS, mod)
      return false unless Dir.exist?(mod_dir)

      enabled = File.read(File.join(mod_dir, 'enabled')).strip
      transition = File.read(File.join(mod_dir, 'transition')).strip

      enabled == '1' && transition == '0'
    rescue SystemCallError
      false
    end
  end
end
