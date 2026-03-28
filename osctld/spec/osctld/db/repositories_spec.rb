# frozen_string_literal: true

require 'osctld/db/repositories'

RSpec.describe OsCtld::DB::Repositories do
  let(:pool) { Struct.new(:name, keyword_init: true).new(name: 'tank') }

  it 'loads and starts the default repository when present' do
    repo = Struct.new(:start) do
      def start; end
    end.new

    stub_const('OsCtld::Repository', Class.new do
      def initialize(*); end
    end)
    allow(OsCtld::Repository).to receive(:new).with(pool, 'default').and_return(repo)
    allow(described_class).to receive(:add)
    allow(repo).to receive(:start)

    described_class.setup(pool)

    expect(described_class).to have_received(:add).with(repo)
    expect(repo).to have_received(:start).once
  end

  it 'creates the default repository when it is missing' do
    stub_const('OsCtld::Repository', Class.new do
      def initialize(*)
        raise Errno::ENOENT
      end
    end)
    stub_const('OsCtld::Commands::Repository::Add', Class.new do
      def self.run(**); end
    end)
    allow(OsCtld::Commands::Repository::Add).to receive(:run)

    described_class.setup(pool)

    expect(OsCtld::Commands::Repository::Add).to have_received(:run).with(
      pool:,
      name: 'default',
      url: 'https://images.vpsadminos.org'
    )
  end
end
