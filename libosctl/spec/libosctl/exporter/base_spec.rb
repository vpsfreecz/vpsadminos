# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'libosctl/config_file'
require 'libosctl/exceptions'
require 'libosctl/exporter/base'
require 'libosctl/system_command_result'
require 'libosctl/utils/log'
require 'libosctl/utils/system'
require 'libosctl/zfs/dataset'

RSpec.describe OsCtl::Lib::Exporter::Base do
  let(:tmpdir) { Dir.mktmpdir('libosctl-spec') }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def root_dataset
    OsCtl::Lib::Zfs::Dataset.new('tank/ct/demo', base: 'tank/ct/demo')
  end

  def data_dataset
    OsCtl::Lib::Zfs::Dataset.new('tank/ct/demo/data', base: 'tank/ct/demo')
  end

  def build_container
    user_config = write_file(tmpdir, 'configs/user.yml', "user: alice\n")
    group_config = write_file(tmpdir, 'configs/group.yml', "group: web\n")

    FakeExporterHelpers::FakeContainer.new(
      id: 'demo',
      rootfs: nil,
      user: FakeExporterHelpers::FakeUser.new(name: 'alice', config_path: user_config),
      group: FakeExporterHelpers::FakeGroup.new(name: 'web', config_path: group_config),
      dataset: root_dataset,
      datasets: [root_dataset, data_dataset],
      config_path: nil
    ).tap do |ct|
      ct.dump_config_value = { 'id' => 'demo', 'distribution' => 'alpine' }
    end
  end

  def build_exporter(archive_io)
    exporter_class = Class.new(described_class) do
      def initialize(*args)
        super
        @datasets = ct.datasets[1..]
      end

      def format
        :fake
      end
    end

    exporter_class.new(build_container, archive_io)
  end

  it 'writes metadata with archive details and relative datasets' do
    archive_io = StringIO.new
    exporter = build_exporter(archive_io)

    allow(Time).to receive(:now).and_return(Time.at(1_700_000_000))

    exporter.dump_metadata('full')
    exporter.close

    metadata = YAML.safe_load(tar_entries(archive_io.string).fetch('metadata.yml'))

    expect(metadata).to eq(
      'type' => 'full',
      'format' => 'fake',
      'user' => 'alice',
      'group' => 'web',
      'container' => 'demo',
      'datasets' => ['data'],
      'exported_at' => 1_700_000_000
    )
  end

  it 'prefers metadata overrides over container values' do
    archive_io = StringIO.new
    exporter = build_exporter(archive_io)

    allow(Time).to receive(:now).and_return(Time.at(1_700_000_100))

    exporter.dump_metadata('skel', id: 'override', user: 'bob', group: 'ops')
    exporter.close

    metadata = YAML.safe_load(tar_entries(archive_io.string).fetch('metadata.yml'))

    expect(metadata).to include(
      'type' => 'skel',
      'container' => 'override',
      'user' => 'bob',
      'group' => 'ops'
    )
  end

  it 'dumps user, group, and container configs by default' do
    archive_io = StringIO.new
    exporter = build_exporter(archive_io)

    exporter.dump_configs
    exporter.close

    entries = tar_entries(archive_io.string)

    expect(entries.fetch('config')).to eq(:directory)
    expect(entries.fetch('config/user.yml')).to eq("user: alice\n")
    expect(entries.fetch('config/group.yml')).to eq("group: web\n")
    expect(YAML.safe_load(entries.fetch('config/container.yml'))).to eq(
      'id' => 'demo',
      'distribution' => 'alpine'
    )
  end

  it 'writes overridden config contents when a block is given' do
    archive_io = StringIO.new
    exporter = build_exporter(archive_io)

    exporter.dump_configs do |dump|
      dump.user("override-user\n")
      dump.group("override-group\n")
      dump.container("override-container\n")
    end
    exporter.close

    entries = tar_entries(archive_io.string)

    expect(entries.fetch('config/user.yml')).to eq("override-user\n")
    expect(entries.fetch('config/group.yml')).to eq("override-group\n")
    expect(entries.fetch('config/container.yml')).to eq("override-container\n")
  end

  it 'raises when the container config is not provided' do
    exporter = build_exporter(StringIO.new)

    expect do
      exporter.dump_configs { |_dump| nil }
    end.to raise_error(RuntimeError, 'container config not set')
  end

  it 'copies hook scripts and creates one-level subdirectories' do
    archive_io = StringIO.new
    exporter = build_exporter(archive_io)
    top_level = write_file(tmpdir, 'hooks/post-start.sh', "echo top\n")
    nested = write_file(tmpdir, 'hooks/pre-start/check.sh', "echo nested\n")

    exporter.dump_user_hook_scripts(
      [
        FakeExporterHelpers::FakeHookScript.new(
          abs_path: top_level,
          rel_path: 'post-start.sh'
        ),
        FakeExporterHelpers::FakeHookScript.new(
          abs_path: nested,
          rel_path: 'pre-start/check.sh'
        )
      ]
    )
    exporter.close

    entries = tar_entries(archive_io.string)

    expect(entries.fetch('hooks')).to eq(:directory)
    expect(entries.fetch('hooks/pre-start')).to eq(:directory)
    expect(entries.fetch('hooks/post-start.sh')).to eq("echo top\n")
    expect(entries.fetch('hooks/pre-start/check.sh')).to eq("echo nested\n")
  end

  it 'rejects hook scripts nested deeper than one level' do
    exporter = build_exporter(StringIO.new)
    deep = write_file(tmpdir, 'hooks/pre-start/check/too-deep.sh', "echo nope\n")

    expect do
      exporter.dump_user_hook_scripts(
        [
          FakeExporterHelpers::FakeHookScript.new(
            abs_path: deep,
            rel_path: 'pre-start/check/too-deep.sh'
          )
        ]
      )
    end.to raise_error(RuntimeError, /too many sublevels/)
  end

  it 'finalizes the archive on close so entries are readable' do
    archive_io = StringIO.new
    exporter = build_exporter(archive_io)

    exporter.dump_metadata('full')
    exporter.close

    expect(tar_entries(archive_io.string)).to include('metadata.yml')
  end
end
