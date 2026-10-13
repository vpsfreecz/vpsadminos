# frozen_string_literal: true

require 'digest'
require_relative 'switch-to-configuration'

RSpec.describe Services do
  subject(:services) { described_class.allocate }

  let(:name) { 'restrict-proc-sysfs' }
  let(:config) { "restrict /sys/module/*/sections\n" }
  let(:new_config) { config }
  let(:old_triggers) { [] }
  let(:old_run) { "#!/bin/sh\nsleep 10\n#{helper_path} #{config_path}\n" }

  def config_path
    "/nix/store/#{'a' * 32}-restrict-proc-sysfs-config.txt"
  end

  def helper_path
    "/nix/store/#{'c' * 32}-restrict-dirs.rb"
  end

  def new_triggers
    ["config-sha256:#{Digest::SHA256.hexdigest(new_config)}"]
  end

  before do
    allow(File).to receive(:realpath).with("/old/etc/runit/services/#{name}/run").and_return('/old-run')
    allow(File).to receive(:realpath).with("/new/etc/runit/services/#{name}/run").and_return('/new-run')
    allow(File).to receive(:read).with('/old-run').and_return(old_run)
    allow(File).to receive(:read).with(config_path).and_return(config)
  end

  def configure_services
    old_service = Services::Service.new(
      name, '/old/etc',
      { 'onChange' => 'restart', 'reloadMethod' => 'reload', 'restartTriggers' => old_triggers },
      { dry_run: true }
    )
    new_service = Services::Service.new(
      name, '/new/etc',
      { 'onChange' => 'ignore', 'reloadMethod' => 'reload', 'restartTriggers' => new_triggers },
      { dry_run: true }
    )
    services.instance_variable_set('@old_services', { name => old_service })
    services.instance_variable_set('@new_services', { name => new_service })
  end

  it 'does not refresh a legacy boot policy just because its implementation changes' do
    configure_services
    expect(services.restart).to be_empty
    expect(services.reload).to be_empty
  end

  context 'when the requested restrictions change' do
    let(:new_config) { "restrict /sys/module/*/sections\nrestrict /sys/example\n" }

    it 'still restarts despite ignoring implementation-only changes' do
      configure_services
      expect(services.restart.map(&:name)).to eq([name])
    end
  end

  context 'with already declared policy inputs' do
    let(:old_triggers) { ["config-sha256:#{Digest::SHA256.hexdigest(config)}"] }

    it 'ignores only implementation changes without reading the legacy script' do
      configure_services
      expect(services.restart).to be_empty
      expect(File).not_to have_received(:read)
    end

    context 'when those inputs change' do
      let(:new_config) { "restrict /sys/another\n" }

      it 'restarts for the changed configuration' do
        configure_services
        expect(services.restart.map(&:name)).to eq([name])
      end
    end
  end

  context 'with an explicit existing trigger' do
    let(:old_triggers) { ['operator-selected-trigger'] }

    it 'does not replace the declared trigger with an inferred input' do
      configure_services
      expect(services.restart.map(&:name)).to eq([name])
      expect(File).not_to have_received(:read)
    end
  end

  context 'with ambiguous legacy configuration inputs' do
    let(:old_run) do
      "#{helper_path} #{config_path}\n" \
        "#{helper_path} /nix/store/#{'b' * 32}-restrict-proc-sysfs-config.txt\n"
    end

    it 'retains the normal restart rather than claiming unchanged configuration' do
      configure_services
      expect(services.restart.map(&:name)).to eq([name])
    end
  end

  context 'with an unrecognized legacy script' do
    let(:old_run) { '#!/bin/sh\ncustom-restrictions\n' }

    it 'retains the normal restart' do
      configure_services
      expect(services.restart.map(&:name)).to eq([name])
    end
  end

  context 'with only a commented-out configuration command' do
    let(:old_run) { "# #{helper_path} #{config_path}\ncustom-restrictions\n" }

    it 'does not infer an applied configuration from the comment' do
      configure_services
      expect(services.restart.map(&:name)).to eq([name])
    end
  end

  [Errno::ENOENT, Errno::EACCES, IOError].each do |error|
    it "does not claim unchanged configuration when the legacy input raises #{error}" do
      allow(File).to receive(:read).with(config_path).and_raise(error)
      configure_services
      expect(services.restart.map(&:name)).to eq([name])
    end
  end

  context 'with an unrelated service' do
    let(:name) { 'another-service' }

    it 'does not infer policy inputs from its script' do
      configure_services
      expect(services.restart.map(&:name)).to eq([name])
      expect(File).not_to have_received(:read)
    end
  end
end
