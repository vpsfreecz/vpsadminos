# frozen_string_literal: true

require 'osctld/history'

RSpec.describe OsCtld::History do
  subject(:history) { described_class.send(:new) }

  def history_path(pool)
    File.join(pool.log_path, '.history')
  end

  it 'creates the history file lazily and writes json lines' do
    with_tmpdir do |dir|
      pool = build_fake_pool(root: dir)

      history.start
      history.log(pool, 'ct-start', ctid: '100')
      history.log(pool, 'ct-stop', ctid: '100')
      history.stop

      expect(File.exist?(history_path(pool))).to be(true)

      rows = File.readlines(history_path(pool), chomp: true).map { |line| JSON.parse(line) }

      expect(rows.map { |row| row['cmd'] }).to eq(%w[ct-start ct-stop])
      expect(rows.map { |row| row['opts'] }).to eq([{ 'ctid' => '100' }, { 'ctid' => '100' }])
    end
  end

  it 'opens and closes file handles through the worker queue' do
    with_tmpdir do |dir|
      pool = build_fake_pool(root: dir)
      path = history_path(pool)

      allow(File).to receive(:open).and_call_original

      history.start
      history.open(pool)
      history.close(pool)
      history.open(pool)
      history.stop

      expect(File).to have_received(:open).with(path, 'a', 0o400).twice
    end
  end

  it 'reads logs through History::Reader helpers' do
    with_tmpdir do |dir|
      pool = build_fake_pool(root: dir)

      history.start
      history.log(pool, 'ct-start', ctid: '100')
      history.log(pool, 'ct-stop', ctid: '100')
      history.stop

      reader = history.read(pool)

      expect(reader).to be_a(described_class::Reader)
      expect(reader.read).to include(cmd: 'ct-start', opts: { ctid: '100' })

      rows = reader.map { |row| row }

      expect(rows.length).to eq(1)
      expect(rows.first).to include(cmd: 'ct-stop', opts: { ctid: '100' })
      expect(rows.first.fetch(:time)).to be_a(Integer)
      expect(reader.eof?).to be(true)

      reader.close
      expect(reader.instance_variable_get(:@f)).to be_closed
    end
  end
end
