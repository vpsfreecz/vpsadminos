# frozen_string_literal: true

require 'fileutils'
require 'spec_helper'

RSpec.describe OsCtl::Exporter::Collectors::KernelProtection do
  let(:registry) { OsCtl::Exporter::Registry.new }
  let(:collector) { described_class.new(instance_double(OsCtl::Exporter::Collector), registry) }

  def status(success)
    instance_double(Process::Status, success?: success, exitstatus: success ? 0 : 1)
  end

  def write_json(path, value)
    File.write(path, JSON.generate(value))
  end

  def collect
    collect_with_registry_swap(registry, collector, build_disconnected_osctld_client)
  end

  it 'exports required and attached BPF livepatch programs' do
    with_tmpdir do |dir|
      ebpf_config = File.join(dir, 'ebpf.json')
      stub_const("#{described_class}::EBPF_CONFIG_PATH", ebpf_config)
      stub_const("#{described_class}::LIVEPATCH_CONFIG_PATH", File.join(dir, 'missing-livepatch.json'))

      write_json(
        ebpf_config,
        {
          'bpftool' => '/bin/bpftool',
          'kernelVersion' => '6.12.87',
          'programs' => [
            {
              'name' => 'ptrace_mm_guard',
              'sinceKernel' => '5.7',
              'untilKernel' => nil,
              'bpfPrograms' => ['ptrace_mm_guard']
            },
            {
              'name' => 'override_uname',
              'sinceKernel' => '5.4',
              'untilKernel' => '6.12.99',
              'bpfPrograms' => %w[uname_fentry uname_fexit]
            }
          ]
        }
      )

      allow(Open3).to receive(:capture3)
        .with('/bin/bpftool', '-j', 'prog', 'show')
        .and_return(
          [
            JSON.generate(
              [
                { 'id' => 10, 'name' => 'ptrace_mm_guard' },
                { 'id' => 11, 'name' => 'uname_fentry' },
                { 'id' => 12, 'name' => 'uname_fexit' }
              ]
            ),
            '',
            status(true)
          ]
        )
      allow(Open3).to receive(:capture3)
        .with('/bin/bpftool', '-j', 'link', 'show')
        .and_return(
          [
            JSON.generate(
              [
                { 'id' => 1, 'prog_id' => 10 },
                { 'id' => 2, 'prog' => { 'id' => 11 } }
              ]
            ),
            '',
            status(true)
          ]
        )

      collect

      expect(metric_values(registry.get(:kernel_bpf_program_required))).to eq(
        {
          { program: 'ptrace_mm_guard', since_kernel: '5.7', until_kernel: '' } => 1.0,
          { program: 'override_uname', since_kernel: '5.4', until_kernel: '6.12.99' } => 1.0
        }
      )
      expect(metric_values(registry.get(:kernel_bpf_program_loaded))).to eq(
        {
          { program: 'ptrace_mm_guard', since_kernel: '5.7', until_kernel: '' } => 1.0,
          { program: 'override_uname', since_kernel: '5.4', until_kernel: '6.12.99' } => 0.0
        }
      )
      expect(metric_values(registry.get(:kernel_protection_monitoring_success))).to eq(
        { { component: 'bpf' } => 1.0 }
      )
    end
  end

  it 'clears stale BPF loaded values when bpftool fails' do
    with_tmpdir do |dir|
      ebpf_config = File.join(dir, 'ebpf.json')
      labels = { program: 'ptrace_mm_guard', since_kernel: '5.7', until_kernel: '' }
      stub_const("#{described_class}::EBPF_CONFIG_PATH", ebpf_config)
      stub_const("#{described_class}::LIVEPATCH_CONFIG_PATH", File.join(dir, 'missing-livepatch.json'))

      write_json(
        ebpf_config,
        {
          'bpftool' => '/bin/bpftool',
          'programs' => [
            {
              'name' => 'ptrace_mm_guard',
              'sinceKernel' => '5.7',
              'untilKernel' => nil,
              'bpfPrograms' => ['ptrace_mm_guard']
            }
          ]
        }
      )

      allow(Open3).to receive(:capture3)
        .with('/bin/bpftool', '-j', 'prog', 'show')
        .and_return(
          [JSON.generate([{ 'id' => 10, 'name' => 'ptrace_mm_guard' }]), '', status(true)],
          ['', 'bpftool failed', status(false)]
        )
      allow(Open3).to receive(:capture3)
        .with('/bin/bpftool', '-j', 'link', 'show')
        .and_return([JSON.generate([{ 'id' => 1, 'prog_id' => 10 }]), '', status(true)])

      collect
      expect(metric_values(registry.get(:kernel_bpf_program_loaded))).to eq({ labels => 1.0 })

      collect
      expect(metric_values(registry.get(:kernel_bpf_program_required))).to eq({ labels => 1.0 })
      expect(metric_values(registry.get(:kernel_bpf_program_loaded))).to eq({ labels => 0.0 })
      expect(metric_values(registry.get(:kernel_protection_monitoring_success))).to eq(
        { { component: 'bpf' } => 0.0 }
      )
    end
  end

  def with_livepatch_kernel_configs
    with_tmpdir do |dir|
      current = File.join(dir, 'current.json')
      booted = File.join(dir, 'booted.json')
      expected = File.join(dir, 'expected-notes')
      running = File.join(dir, 'running-notes')
      sysfs = File.join(dir, 'livepatch')
      image = File.join(dir, 'kernel-image')
      booted_image = File.join(dir, 'booted-image')
      stub_const("#{described_class}::EBPF_CONFIG_PATH", File.join(dir, 'missing-ebpf.json'))
      stub_const("#{described_class}::LIVEPATCH_CONFIG_PATH", current)
      stub_const("#{described_class}::BOOTED_LIVEPATCH_CONFIG_PATH", booted)
      stub_const("#{described_class}::KERNEL_NOTES_PATH", running)
      stub_const("#{described_class}::LIVEPATCH_SYSFS", sysfs)
      stub_const("#{described_class}::BOOTED_KERNEL_IMAGE_PATH", booted_image)
      File.write(image, 'kernel-image')
      File.symlink(image, booted_image)
      File.binwrite(expected, "new-kernel\x00notes")
      File.binwrite(running, "new-kernel\x00notes")
      write_json(current, {
                   'module' => 'livepatch_6_nfs_cancel', 'patchVersion' => 6,
                   'kernelNotes' => expected, 'kernelImage' => image
                 })
      %w[livepatch_6 livepatch_6_nfs_cancel].each do |name|
        path = File.join(sysfs, name)
        FileUtils.mkdir_p(path)
        File.write(File.join(path, 'enabled'), "1\n")
        File.write(File.join(path, 'transition'), "0\n")
      end
      yield booted, running, expected
    end
  end

  it 'monitors the current variant only when its exact boot notes match' do
    with_livepatch_kernel_configs do
      collect

      expect(metric_values(registry.get(:kernel_livepatch_loaded))).to eq(
        { { module: 'livepatch_6_nfs_cancel', patch_version: '6' } => 1.0 }
      )
    end
  end

  it 'monitors the booted generation after an OS switch before reboot' do
    with_livepatch_kernel_configs do |booted, running, _expected|
      File.binwrite(running, "old-kernel\x00notes")
      write_json(booted, { 'module' => 'livepatch_6', 'patchVersion' => 6 })
      collect

      expect(metric_values(registry.get(:kernel_livepatch_loaded))).to eq(
        { { module: 'livepatch_6', patch_version: '6' } => 1.0 }
      )
      expect(metric_values(registry.get(:kernel_protection_monitoring_success))).to eq(
        { { component: 'livepatch' } => 1.0 }
      )
    end
  end

  it 'fails monitoring when neither generation matches the running kernel' do
    with_livepatch_kernel_configs do |booted, running, expected|
      File.binwrite(running, "unknown-kernel\x00notes")
      write_json(booted, { 'module' => 'livepatch_6', 'patchVersion' => 6, 'kernelNotes' => expected })
      collect

      expect(metric_values(registry.get(:kernel_livepatch_loaded))).to be_empty
      expect(metric_values(registry.get(:kernel_protection_monitoring_success))).to eq(
        { { component: 'livepatch' } => 0.0 }
      )
    end
  end

  it 'does not accept identical legacy notes for a different boot image' do
    with_livepatch_kernel_configs do |booted, _running, _expected|
      cfg = JSON.parse(File.read(described_class::LIVEPATCH_CONFIG_PATH))
      cfg['kernelImage'] = '/different-kernel-image'
      write_json(described_class::LIVEPATCH_CONFIG_PATH, cfg)
      write_json(booted, { 'module' => 'livepatch_6', 'patchVersion' => 6 })
      collect

      expect(metric_values(registry.get(:kernel_livepatch_loaded))).to eq(
        { { module: 'livepatch_6', patch_version: '6' } => 1.0 }
      )
    end
  end

  it 'fails monitoring if the boot image cannot be identified' do
    with_livepatch_kernel_configs do
      File.unlink(described_class::BOOTED_KERNEL_IMAGE_PATH)
      collect

      expect(metric_values(registry.get(:kernel_protection_monitoring_success))).to eq(
        { { component: 'livepatch' } => 0.0 }
      )
    end
  end

  it 'does not consider empty kernel notes an identity match' do
    with_livepatch_kernel_configs do |_booted, running, expected|
      File.binwrite(running, '')
      File.binwrite(expected, '')
      collect

      expect(metric_values(registry.get(:kernel_protection_monitoring_success))).to eq(
        { { component: 'livepatch' } => 0.0 }
      )
    end
  end

  it 'exports kernel livepatch status from sysfs' do
    with_tmpdir do |dir|
      livepatch_config = File.join(dir, 'livepatch.json')
      livepatch_sysfs = File.join(dir, 'sys', 'kernel', 'livepatch')
      module_dir = File.join(livepatch_sysfs, 'livepatch_2')
      labels = { module: 'livepatch_2', patch_version: '2' }

      stub_const("#{described_class}::EBPF_CONFIG_PATH", File.join(dir, 'missing-ebpf.json'))
      stub_const("#{described_class}::LIVEPATCH_CONFIG_PATH", livepatch_config)
      stub_const("#{described_class}::LIVEPATCH_SYSFS", livepatch_sysfs)

      write_json(livepatch_config, { 'module' => 'livepatch_2', 'patchVersion' => 2 })
      FileUtils.mkdir_p(module_dir)
      File.write(File.join(module_dir, 'enabled'), "1\n")
      File.write(File.join(module_dir, 'transition'), "0\n")

      collect

      expect(metric_values(registry.get(:kernel_livepatch_required))).to eq(
        { labels => 1.0 }
      )
      expect(metric_values(registry.get(:kernel_livepatch_loaded))).to eq(
        { labels => 1.0 }
      )
      expect(metric_values(registry.get(:kernel_protection_monitoring_success))).to eq(
        { { component: 'livepatch' } => 1.0 }
      )

      File.write(File.join(module_dir, 'transition'), "1\n")
      collect

      expect(metric_values(registry.get(:kernel_livepatch_loaded))).to eq(
        { labels => 0.0 }
      )
    end
  end
end
