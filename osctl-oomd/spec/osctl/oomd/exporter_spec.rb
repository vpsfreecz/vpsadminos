# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Oomd::Exporter do
  it 'writes container and global metrics to the requested file' do
    with_tmpdir do |dir|
      file = File.join(dir, 'metrics', 'oomd.prom')
      container = OsCtl::Oomd::Killer::Container.new('tank', 'ct1')
      2.times { container.hit }
      killer = instance_double(OsCtl::Oomd::Killer, export: [container], restart_hits: 8, stop_hits: 40)
      exporter = described_class.new(file:, killer:)

      exporter.send(:export_metrics)

      output = File.read(file)
      expect(output).to include('osctl_oomd_container_restart_hits')
      expect(output).to include('pool="tank",id="ct1"')
      expect(output).to include('osctl_oomd_restart_hits 8')
      expect(output).to include('osctl_oomd_stop_hits 40')
    end
  end

  it 'creates parent directories and regenerates the metrics file' do
    with_tmpdir do |dir|
      file = File.join(dir, 'metrics', 'oomd.prom')
      killer = instance_double(OsCtl::Oomd::Killer, export: [], restart_hits: 8, stop_hits: 40)
      exporter = described_class.new(file:, killer:)

      allow(FileUtils).to receive(:mkdir_p).and_call_original
      allow(exporter).to receive(:regenerate_file).and_call_original

      exporter.send(:export_metrics)

      expect(FileUtils).to have_received(:mkdir_p).with(File.dirname(file))
      expect(exporter).to have_received(:regenerate_file).with(file, 0o644)
    end
  end

  it 'stops the exporter loop when stop is requested' do
    with_tmpdir do |dir|
      killer = instance_double(OsCtl::Oomd::Killer, export: [], restart_hits: 8, stop_hits: 40)
      exporter = described_class.new(file: File.join(dir, 'oomd.prom'), killer:)
      allow(exporter).to receive(:export_metrics)

      exporter.start
      exporter.stop

      expect(exporter.instance_variable_get(:@thread).join(2)).to be_truthy
    end
  end
end
