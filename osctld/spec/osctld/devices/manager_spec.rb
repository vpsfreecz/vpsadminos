# frozen_string_literal: true

# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles

require 'osctld/devices/change_set'
require 'osctld/devices/configurator'
require 'osctld/devices/device'
require 'osctld/devices/lock'
require 'osctld/devices/manager'
require 'osctld/devices/mode'

RSpec.describe OsCtld::Devices::Manager do
  let(:pool) { double(name: 'tank') }
  let(:owner) { double(pool: pool, save_config: nil) }
  let(:configurator_class) do
    Class.new(OsCtld::Devices::Configurator) do
      attr_reader :events

      def initialize(owner)
        super
        @events = []
      end

      def init(devices)
        @events << [:init, devices.map(&:to_s)]
      end

      def add_device(device)
        @events << [:add, device.to_s]
      end

      def remove_device(device)
        @events << [:remove, device.to_s]
      end

      def reconfigure(devices)
        @events << [:reconfigure, devices.map(&:to_s)]
      end

      def apply_changes(changes)
        @events << [:changes, changes]
      end
    end
  end
  let(:manager_class) do
    config_class = configurator_class

    Class.new(described_class) do
      define_method(:parent) { nil }
      define_method(:children) { [] }
      define_method(:changeset_sort_key) { 'self' }
      define_method(:configurator_class) { config_class }
    end
  end
  let(:device) { OsCtld::Devices::Device.new(:char, 1, 3, 'rw', inherit: false, inherited: false) }
  let(:second_device) { OsCtld::Devices::Device.new(:block, 8, 0, 'rw', inherit: false, inherited: false) }
  let(:manager) { manager_class.new(owner) }

  before do
    allow(OsCtld::Devices::Lock).to receive(:sync).and_yield
    allow(OsCtld::Devices::ChangeSet).to receive(:add)
  end

  it 'persists add-only replacements' do
    manager.replace([device])

    expect(owner).to have_received(:save_config)
    expect(manager.dump).to eq([device.dump])
  end

  it 'persists replacements that add and chmod devices' do
    original = OsCtld::Devices::Device.new(:char, 1, 3, 'r', inherit: false, inherited: true)
    manager = manager_class.new(owner, devices: [original])

    manager.replace([
                      OsCtld::Devices::Device.new(:char, 1, 3, 'rw', inherit: false, inherited: false),
                      second_device
                    ])

    expect(owner).to have_received(:save_config).at_least(:once)
    expect(manager.dump).to contain_exactly(
      include('mode' => 'rw'),
      include('major' => 8, 'minor' => 0)
    )
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/VerifiedDoubles
