# frozen_string_literal: true

require 'osctld/utmp_reader'

RSpec.describe OsCtld::UtmpReader do
  describe '.read' do
    it 'opens the requested path and parses its entries' do
      with_tmpdir do |dir|
        path = File.join(dir, 'utmp')
        write_utmp(
          path,
          [
            build_utmp_entry(user: 'alice', line: 'pts/1', id: 'p1'),
            build_utmp_entry(user: 'bob', line: 'pts/2', id: 'p2', pid: 4321)
          ]
        )

        allow(File).to receive(:open).and_wrap_original do |orig, open_path, *args, &block|
          expect(open_path).to eq(path)
          orig.call(open_path, *args, &block)
        end

        entries = described_class.read(path)

        expect(entries.map(&:ut_user)).to eq(%w[alice bob])
        expect(entries.map(&:ut_line)).to eq(%w[pts/1 pts/2])
      end
    end
  end

  describe '.read_utmp_fhs' do
    it 'falls back from /run/utmp to /var/log/utmp' do
      with_tmpdir do |dir|
        path = File.join(dir, 'utmp')
        write_utmp(path, [build_utmp_entry(user: 'carol', line: 'pts/3', id: 'p3')])

        allow(File).to receive(:open).and_wrap_original do |orig, open_path, *args, &block|
          case open_path
          when '/run/utmp'
            raise Errno::ENOENT, open_path
          when '/var/log/utmp'
            orig.call(path, *args, &block)
          else
            orig.call(open_path, *args, &block)
          end
        end

        entries = described_class.read_utmp_fhs

        expect(entries.map(&:ut_user)).to eq(['carol'])
      end
    end
  end
end
