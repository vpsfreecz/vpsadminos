# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass

require 'osctld/exceptions'
require 'osctld/command'
require 'osctld/id_range'

module OsCtld
  module Commands
    module IdRange; end
  end
end

require 'osctld/commands/id_range/assets'
require 'osctld/commands/id_range/create'
require 'osctld/commands/id_range/delete'
require 'osctld/commands/id_range/free'
require 'osctld/commands/id_range/list'
require 'osctld/commands/id_range/show'
require 'osctld/commands/id_range/allocate'
require 'osctld/commands/id_range/set'
require 'osctld/commands/id_range/table_list'
require 'osctld/commands/id_range/table_show'
require 'osctld/commands/id_range/unset'

RSpec.describe 'id_range commands' do
  let(:range) do
    Struct.new(:pool, :name, :allocation, keyword_init: true) do
      attr_accessor :set_changes, :unset_changes, :freed

      def export
        { name:, pool: pool.name, free: 10 }
      end

      def assets
        [{ path: "/id-range/#{name}" }]
      end

      def allocate(block_count, block_index:, owner:)
        self.allocation = [block_count, block_index, owner]
        { block_index: 3, block_count: }
      end

      def can_delete?
        true
      end

      def config_path
        "/id-range/#{name}.yml"
      end

      def manipulate(_holder, block:, &)
        yield
      end

      def set(changes)
        self.set_changes = changes
      end

      def unset(changes)
        self.unset_changes = changes
      end

      def export_all
        [{ block_index: 0, type: :free }]
      end

      def export_allocated
        [{ block_index: 1, type: :allocated }]
      end

      def export_free
        [{ block_index: 2, type: :free }]
      end

      def export_at(index)
        { block_index: index, type: :free }
      end

      def free_at(index)
        self.freed = [:block_index, index]
      end

      def free_by(owner)
        self.freed = [:owner, owner]
      end

      def block_count
        8
      end
    end.new(pool: Struct.new(:name).new('tank'), name: 'default', allocation: nil)
  end

  before do
    history = stub_const('OsCtld::History', Class.new do
      def self.log(*); end
    end)
    allow(history).to receive(:log)
  end

  it 'lists and shows exported id ranges' do
    db = stub_const('OsCtld::DB::IdRanges', Class.new do
      def self.each_by_ids(_names, _pool); end

      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:each_by_ids).with(['default'], 'tank').and_yield(range)
    allow(db).to receive(:find).with('default', 'tank').and_return(range)

    expect(OsCtld::Commands::IdRange::List.run(names: ['default'], pool: 'tank')).to eq(
      status: true,
      output: [{ name: 'default', pool: 'tank', free: 10 }]
    )
    expect(OsCtld::Commands::IdRange::Show.run(name: 'default', pool: 'tank')).to eq(
      status: true,
      output: { name: 'default', pool: 'tank', free: 10 }
    )
  end

  it 'creates id ranges in the selected pool after validating sizes' do
    pool_class = stub_const('OsCtld::Pool', Class.new do
      attr_reader :name

      def initialize(name)
        @name = name
      end
    end)
    pool = pool_class.new('tank')
    range_class = stub_const('OsCtld::IdRange', Class.new do
      attr_reader :pool, :name, :configured

      def initialize(pool, name, load: false)
        @pool = pool
        @name = name
      end

      def configure(start_id, block_size, block_count)
        @configured = [start_id, block_size, block_count]
      end
    end)
    pools = stub_const('OsCtld::DB::Pools', Class.new do
      def self.find(_name); end

      def self.get_or_default(_name); end
    end)
    ranges = stub_const('OsCtld::DB::IdRanges', Class.new do
      def self.sync
        yield
      end

      def self.find(_name, _pool); end

      def self.add(_range); end
    end)
    allow(pools).to receive(:find).with('tank').and_return(pool)
    allow(ranges).to receive(:find).with('default', pool).and_return(nil)
    allow(ranges).to receive(:add).with(instance_of(range_class))

    expect(
      OsCtld::Commands::IdRange::Create.run(
        name: 'default',
        pool: 'tank',
        start_id: 100_000,
        block_size: 65_536,
        block_count: 4
      )
    ).to eq(status: true, output: nil)
  end

  it 'exports assets through the asset validator' do
    db = stub_const('OsCtld::DB::IdRanges', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('default', 'tank').and_return(range)
    command = OsCtld::Commands::IdRange::Assets.new({ name: 'default', pool: 'tank' }, {})
    allow(command).to receive(:list_and_validate_assets).with(range).and_return([{ path: '/id-range/default' }])

    expect(command.execute).to eq(status: true, output: [{ path: '/id-range/default' }])
  end

  it 'allocates blocks with the requested options and validates block_count' do
    db = stub_const('OsCtld::DB::IdRanges', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('default', 'tank').and_return(range)

    expect(
      OsCtld::Commands::IdRange::Allocate.run(
        name: 'default',
        pool: 'tank',
        block_count: 2,
        block_index: 4,
        owner: 'ct:ct1'
      )
    ).to eq(status: true, output: { block_index: 3, block_count: 2 })
    expect(range.allocation).to eq([2, 4, 'ct:ct1'])

    expect do
      OsCtld::Commands::IdRange::Allocate.run!(
        name: 'default',
        pool: 'tank',
        block_count: 0
      )
    end.to raise_error(OsCtld::CommandFailed, 'block_count has to be greater than 1')
  end

  it 'maps allocation errors to command errors' do
    db = stub_const('OsCtld::DB::IdRanges', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('default', 'tank').and_return(range)
    allow(range).to receive(:allocate).and_raise(OsCtld::IdRange::AllocationError, 'no space')

    expect(
      OsCtld::Commands::IdRange::Allocate.run(name: 'default', pool: 'tank', block_count: 2)
    ).to eq(status: false, message: 'no space')
  end

  it 'deletes ranges, frees allocations, and filters set/unset changes' do
    db = stub_const('OsCtld::DB::IdRanges', Class.new do
      def self.find(_name, _pool); end

      def self.remove(_range); end
    end)
    allow(db).to receive(:find).with('default', 'tank').and_return(range)
    allow(db).to receive(:remove).with(range)
    allow(File).to receive(:unlink).with('/id-range/default.yml')

    expect(OsCtld::Commands::IdRange::Free.run(name: 'default', pool: 'tank', block_index: 2)).to eq(status: true, output: nil)
    expect(range.freed).to eq([:block_index, 2])
    expect(OsCtld::Commands::IdRange::Set.run(name: 'default', pool: 'tank', attrs: { owner: 'ops' })).to eq(status: true, output: nil)
    expect(range.set_changes).to eq(attrs: { owner: 'ops' })
    expect(OsCtld::Commands::IdRange::Unset.run(name: 'default', pool: 'tank', attrs: %w[owner])).to eq(status: true, output: nil)
    expect(range.unset_changes).to eq(attrs: %w[owner])
    expect(OsCtld::Commands::IdRange::Delete.run(name: 'default', pool: 'tank')).to eq(status: true, output: nil)
    expect(db).to have_received(:remove).with(range)
  end

  it 'shows full or filtered allocation tables and validates block indexes' do
    db = stub_const('OsCtld::DB::IdRanges', Class.new do
      def self.find(_name, _pool); end
    end)
    allow(db).to receive(:find).with('default', 'tank').and_return(range)

    expect(OsCtld::Commands::IdRange::TableList.run(name: 'default', pool: 'tank')).to eq(
      status: true,
      output: [{ block_index: 0, type: :free }]
    )
    expect(OsCtld::Commands::IdRange::TableList.run(name: 'default', pool: 'tank', type: 'allocated')).to eq(
      status: true,
      output: [{ block_index: 1, type: :allocated }]
    )
    expect(OsCtld::Commands::IdRange::TableShow.run(name: 'default', pool: 'tank', block_index: 3)).to eq(
      status: true,
      output: { block_index: 3, type: :free }
    )

    expect do
      OsCtld::Commands::IdRange::TableShow.run!(name: 'default', pool: 'tank', block_index: 9)
    end.to raise_error(OsCtld::CommandFailed, 'block_index out of range')
  end
end

# rubocop:enable RSpec/DescribeClass
