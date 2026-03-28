# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/VerifiedDoubles

require 'socket'

require 'osctld/assets'
require 'osctld/assets/base'
require 'osctld/assets/definition'
require 'osctld/assets/validator'
require 'osctld/assets/directory'
require 'osctld/assets/file'
require 'osctld/assets/symlink'
require 'osctld/assets/unix_socket'
require 'osctld/assets/dataset'
require 'osctld/assets/cgroup_device_list'
require 'osctld/assets/cgroup_program'
require 'osctld/devices/device'
require 'osctld/devices/mode'
require 'osctld/utils/assets'

RSpec.describe 'OsCtld assets' do
  let(:validator) { OsCtld::Assets::Validator.new }

  describe OsCtld::Assets do
    it 'registers types and resolves them by type' do
      expect(described_class.for_type(:directory)).to eq(OsCtld::Assets::Directory)
      expect(described_class.for_type(:file)).to eq(OsCtld::Assets::File)
    end
  end

  describe OsCtld::Assets::Definition::Scope do
    it 'exposes the asset DSL for registered asset types' do
      scope = described_class.new

      scope.directory('/tmp/test', optional: true)
      scope.file('/tmp/test-file', user: 0)

      expect(scope.assets.map(&:class)).to eq([
                                                OsCtld::Assets::Directory,
                                                OsCtld::Assets::File
                                              ])
    end
  end

  describe OsCtld::Assets::Validator do
    it 'prefetches the union of datasets and properties and validates assets in order' do
      calls = []
      property_reader = instance_double(OsCtl::Lib::Zfs::PropertyReader, read: {})

      asset_a = Object.new
      asset_a.define_singleton_method(:prefetch_zfs) { [%w[tank/one tank/two], %w[mountpoint uidmap]] }
      asset_a.define_singleton_method(:run_validation) do |run|
        calls << [:a, run.dataset_tree]
      end

      asset_b = Object.new
      asset_b.define_singleton_method(:prefetch_zfs) { [%w[tank/two tank/three], %w[gidmap custom]] }
      asset_b.define_singleton_method(:run_validation) do |run|
        calls << [:b, run.dataset_tree]
      end

      allow(OsCtl::Lib::Zfs::PropertyReader).to receive(:new).and_return(property_reader)

      described_class.new([asset_a, asset_b]).validate

      expect(property_reader).to have_received(:read).with(
        contain_exactly('tank/one', 'tank/two', 'tank/three'),
        contain_exactly('mountpoint', 'uidmap', 'gidmap', 'custom'),
        recursive: false,
        ignore_error: true
      )
      expect(calls).to eq([[:a, {}], [:b, {}]])
    end
  end

  describe OsCtld::Utils::Assets do
    it 'exports validated assets' do
      host = Class.new do
        include OsCtld::Utils::Assets
      end.new

      with_tmpdir do |dir|
        path = File.join(dir, 'item')
        Dir.mkdir(path)
        asset = OsCtld::Assets::Directory.new(path, user: Process.uid, group: Process.gid)
        entity = double(assets: [asset])

        exported = host.list_and_validate_assets(entity)

        expect(exported).to contain_exactly(
          include(
            type: :directory,
            path: path,
            state: :valid,
            errors: []
          )
        )
      end
    end
  end

  describe 'typed file assets' do
    def validate_asset(asset)
      validator = OsCtld::Assets::Validator.new([asset])
      validator.validate
      asset
    end

    it 'rejects an optional directory when a file exists at the path' do
      with_tmpdir do |dir|
        path = File.join(dir, 'entry')
        File.write(path, 'x')

        asset = validate_asset(OsCtld::Assets::Directory.new(path, optional: true))

        expect(asset.state).to eq(:invalid)
        expect(asset.errors).to include('not a directory')
      end
    end

    it 'rejects an optional file when a directory exists at the path' do
      with_tmpdir do |dir|
        path = File.join(dir, 'entry')
        Dir.mkdir(path)

        asset = validate_asset(OsCtld::Assets::File.new(path, optional: true))

        expect(asset.state).to eq(:invalid)
        expect(asset.errors).to include('not a file')
      end
    end

    it 'rejects an optional symlink when a regular file exists at the path' do
      with_tmpdir do |dir|
        path = File.join(dir, 'entry')
        File.write(path, 'x')

        asset = validate_asset(OsCtld::Assets::Symlink.new(path, optional: true))

        expect(asset.state).to eq(:invalid)
        expect(asset.errors).to include('not a symlink')
      end
    end

    it 'rejects an optional socket when a regular file exists at the path' do
      with_tmpdir do |dir|
        path = File.join(dir, 'entry.sock')
        File.write(path, 'x')

        asset = validate_asset(OsCtld::Assets::UnixSocket.new(path, optional: true))

        expect(asset.state).to eq(:invalid)
        expect(asset.errors).to include('not a socket')
      end
    end

    it 'accepts optional missing typed assets' do
      with_tmpdir do |dir|
        missing = File.join(dir, 'missing')

        [
          OsCtld::Assets::Directory.new(missing, optional: true),
          OsCtld::Assets::File.new(missing, optional: true),
          OsCtld::Assets::Symlink.new(missing, optional: true),
          OsCtld::Assets::UnixSocket.new(missing, optional: true)
        ].each do |asset|
          validate_asset(asset)
          expect(asset.state).to eq(:valid)
          expect(asset.errors).to be_empty
        end
      end
    end
  end

  describe OsCtld::Assets::Dataset do
    it 'validates dataset mountpoint metadata, ownership, maps, and custom properties' do
      with_tmpdir do |dir|
        File.chmod(0o755, dir)

        dataset = Struct.new(:properties, keyword_init: true).new(
          properties: {
            'mountpoint' => dir,
            'uidmap' => '0:100000:65536',
            'gidmap' => '0:200000:65536',
            'compression' => 'lz4'
          }
        )
        property_reader = instance_double(
          OsCtl::Lib::Zfs::PropertyReader,
          read: { 'tank/ct' => dataset }
        )

        allow(OsCtl::Lib::Zfs::PropertyReader).to receive(:new).and_return(property_reader)

        asset = described_class.new(
          'tank/ct',
          uidmap: [[0, 100_000, 65_536]],
          gidmap: [[0, 200_000, 65_536]],
          user: Process.uid,
          group: Process.gid,
          mode: 0o755,
          properties: { 'compression' => 'lz4' }
        )

        OsCtld::Assets::Validator.new([asset]).validate

        expect(asset.state).to eq(:valid)
      end
    end
  end

  describe OsCtld::Assets::CgroupDeviceList do
    let(:device) { OsCtld::Devices::Device.new(:char, 1, 3, 'rwm') }

    it 'records a validation error when devices.list is missing without raising' do
      with_tmpdir do |dir|
        asset = described_class.new(File.join(dir, 'missing'), devices: [device])

        expect { OsCtld::Assets::Validator.new([asset]).validate }.not_to raise_error
        expect(asset.state).to eq(:invalid)
        expect(asset.errors).to include("devices.list not found in cgroup #{File.join(dir, 'missing').inspect}")
      end
    end

    it 'validates matching devices.list content' do
      with_tmpdir do |dir|
        File.write(File.join(dir, 'devices.list'), "#{device}\n")
        asset = described_class.new(dir, devices: [device])

        OsCtld::Assets::Validator.new([asset]).validate

        expect(asset.state).to eq(:valid)
      end
    end
  end

  describe OsCtld::Assets::CgroupProgram do
    it 'reports parser errors from bpftool output' do
      with_tmpdir do |dir|
        asset = described_class.new(dir, program_name: 'dev-test')
        allow(asset).to receive(:syscmd).and_return(double(output: '{'))

        OsCtld::Assets::Validator.new([asset]).validate

        expect(asset.state).to eq(:invalid)
        expect(asset.errors.first).to match(/failed to parse bpftool output/)
      end
    end

    it 'accepts a matching attached program' do
      with_tmpdir do |dir|
        asset = described_class.new(
          dir,
          program_name: 'dev-test',
          attach_type: 'cgroup_device',
          attach_flags: 'multi'
        )
        allow(asset).to receive(:syscmd).and_return(
          double(output: [{ name: 'dev-test', attach_type: 'cgroup_device', attach_flags: 'multi' }].to_json)
        )

        OsCtld::Assets::Validator.new([asset]).validate

        expect(asset.state).to eq(:valid)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/VerifiedDoubles
