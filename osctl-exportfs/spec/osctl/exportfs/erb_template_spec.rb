# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::ErbTemplate do
  let(:method_source) do
    Class.new do
      def server_name
        'gamma'
      end
    end.new
  end
  let(:nfsd_config) do
    instance_double(
      OsCtl::ExportFS::Config::Nfsd,
      port: nil,
      tcp: true,
      udp: false,
      allowed_versions: [],
      disallowed_versions: [],
      syslog: false,
      nproc: 8
    )
  end
  let(:config) do
    instance_double(
      OsCtl::ExportFS::Config::TopLevel,
      nfsd: nfsd_config,
      mountd_port: nil,
      statd_port: nil,
      lockd_port: nil
    )
  end
  let(:server) { instance_double(OsCtl::ExportFS::Server, nfs_state: '/var/lib/nfs') }

  it 'renders templates with plain values, procs, and methods' do
    plain = described_class.render('runsv', name: 'alpha')
    from_proc = described_class.render('runsv', name: proc { 'beta' })
    from_method = described_class.render('runsv', name: method_source.method(:server_name))

    expect(plain).to include('server spawn alpha')
    expect(from_proc).to include('server spawn beta')
    expect(from_method).to include('server spawn gamma')
  end

  it 'renders templates to files and rewrites changed output only' do
    with_tmpdir do |tmpdir|
      path = File.join(tmpdir, 'run')

      described_class.render_to('runsv', { name: 'alpha' }, path)
      expect(File.read(path)).to include('server spawn alpha')

      stat_before = File.stat(path)
      described_class.render_to_if_changed('runsv', { name: 'alpha' }, path)
      expect(File.stat(path).ino).to eq(stat_before.ino)
      expect(File).not_to exist("#{path}.new")

      described_class.render_to_if_changed('runsv', { name: 'beta' }, path)
      expect(File.read(path)).to include('server spawn beta')
    end
  end

  it 'renders runit service scripts with the server system path' do
    {
      'runit/1' => {},
      'runit/2' => {},
      'runit/3' => {},
      'runsvdir/rpcbind' => {},
      'runsvdir/nfsd' => { server:, config: },
      'runsvdir/statd' => { server:, config: }
    }.each do |template, vars|
      expect(described_class.render(template, vars)).to include(
        'export PATH=/run/current-system/sw/bin'
      )
    end
  end
end
