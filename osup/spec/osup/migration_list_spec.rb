# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsUp::MigrationList do
  def create_entry(dir, name, directory: true)
    path = File.join(dir, name)

    if directory
      Dir.mkdir(path)
    else
      File.write(path, '')
    end
  end

  it 'loads and sorts visible migration directories by id' do
    with_tmpdir do |dir|
      create_entry(dir, '.hidden')
      create_entry(dir, '20200101000000-file', directory: false)
      create_entry(dir, '20200102030405-second')
      create_entry(dir, '20190101010101-first')

      allow(OsUp).to receive(:migration_dir).and_return(dir)

      list = fresh_singleton(described_class)

      expect(list.get.map(&:id)).to eq([20_190_101_010_101, 20_200_102_030_405])
      expect(list[20_190_101_010_101].name).to eq('First')
      expect(list.count).to eq(2)
    end
  end

  it 'returns a copy from get' do
    with_tmpdir do |dir|
      create_entry(dir, '20190101010101-first')
      allow(OsUp).to receive(:migration_dir).and_return(dir)

      list = fresh_singleton(described_class)
      copy = list.get
      copy.clear

      expect(list.count).to eq(1)
    end
  end

  describe 'class delegators' do
    let(:instance) { instance_double(described_class) }

    before do
      allow(described_class).to receive(:instance).and_return(instance)
    end

    it 'delegates [] to the singleton instance' do
      allow(instance).to receive(:[]).with(42).and_return(:migration)

      expect(described_class[42]).to eq(:migration)
    end

    it 'delegates each to the singleton instance' do
      allow(instance).to receive(:each).and_yield(:migration)

      yielded = []
      # rubocop:disable Style/MapIntoArray
      described_class.each { |migration| yielded << migration }
      # rubocop:enable Style/MapIntoArray

      expect(yielded).to eq([:migration])
    end

    it 'delegates count to the singleton instance' do
      allow(instance).to receive(:count).and_return(2)

      expect(described_class.count).to eq(2)
    end

    it 'delegates get to the singleton instance' do
      allow(instance).to receive(:get).and_return([:migration])

      expect(described_class.get).to eq([:migration])
    end
  end
end
