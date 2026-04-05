# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Image::FixFileCapabilities do
  subject(:op) { described_class.new(image, install_dir) }

  let(:image) { instance_double(OsCtl::Image::Image, name: 'alpine') }
  let(:install_dir) { Dir.mktmpdir }

  after do
    FileUtils.remove_entry(install_dir)
  end

  def with_fake_getcap(script)
    Dir.mktmpdir do |bin_dir|
      path = File.join(bin_dir, 'getcap')
      File.write(path, script)
      File.chmod(0o755, path)
      old_path = ENV.fetch('PATH', nil)
      ENV['PATH'] = [bin_dir, old_path].compact.join(':')
      yield
    ensure
      ENV['PATH'] = old_path
    end
  end

  it 'parses file capabilities reported by getcap' do
    with_fake_getcap(<<~SH) do
      #!/bin/sh
      printf '%s\n' '/file cap_setuid,cap_net_raw=ep'
    SH
      caps = op.send(:read_capabilities)

      expect(caps.map(&:file)).to eq(['/file'])
      expect(caps.map(&:caps)).to eq([%w[cap_setuid cap_net_raw]])
      expect(caps.map(&:flags)).to eq(['ep'])
    end
  end

  it 'skips file names with spaces and logs a warning' do
    allow(OsCtl::Lib::Utils::Log::PrivateMethods).to receive(:log)

    with_fake_getcap(<<~SH) do
      #!/bin/sh
      printf '%s\n' '/file with spaces cap_setuid=ep'
    SH
      expect(op.send(:read_capabilities)).to eq([])
    end

    expect(OsCtl::Lib::Utils::Log::PrivateMethods).to have_received(:log).with(
      :warn,
      'filecaps alpine',
      include('Unhandled file capability')
    )
  end

  it 'raises on inconsistent capability flags' do
    with_fake_getcap(<<~SH) do
      #!/bin/sh
      printf '%s\n' '/file cap_setuid=ep,cap_net_raw=ei'
    SH
      expect { op.send(:read_capabilities) }
        .to raise_error(OsCtl::Image::OperationError, /unexpected capability/)
    end
  end

  it 'raises when getcap exits non-zero' do
    with_fake_getcap(<<~SH) do
      #!/bin/sh
      exit 1
    SH
      expect { op.send(:read_capabilities) }
        .to raise_error(OsCtl::Image::OperationError, 'getcap failed with exit status 1')
    end
  end

  it 'runs setcap for each file capability' do
    file_cap = described_class::FileCapability.new('/file', %w[cap_setuid cap_net_raw], 'ep')
    allow(Kernel).to receive(:system).and_return(true)

    op.send(:fix_capabilities, [file_cap])

    expect(Kernel).to have_received(:system).with('setcap', 'cap_setuid,cap_net_raw=ep', '/file')
  end

  it 'raises when setcap fails' do
    file_cap = described_class::FileCapability.new('/file', %w[cap_setuid], 'ep')
    allow(Kernel).to receive(:system).and_return(false)

    expect { op.send(:fix_capabilities, [file_cap]) }
      .to raise_error(OsCtl::Image::OperationError, 'failed to set file capability /file cap_setuid=ep')
  end
end
