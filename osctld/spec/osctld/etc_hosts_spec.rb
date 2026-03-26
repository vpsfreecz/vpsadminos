# frozen_string_literal: true

require 'osctld/etc_hosts'
require 'libosctl/hostname'

RSpec.describe OsCtld::EtcHosts do
  def hosts(path)
    File.read(path)
  end

  it 'creates localhost records for a missing file' do
    with_tmpdir do |dir|
      path = File.join(dir, 'hosts')
      described_class.new(path).set(OsCtl::Lib::Hostname.new('node.example.com'))

      expect(hosts(path)).to include('127.0.0.1 node.example.com node localhost')
      expect(hosts(path)).to include('::1 node.example.com node localhost ip6-localhost ip6-loopback')
      expect(hosts(path)).to include(described_class::NOTICE_HEAD)
      expect(hosts(path)).to include(described_class::NOTICE_TAIL)
    end
  end

  it 'preserves unrelated lines when updating an existing file' do
    with_tmpdir do |dir|
      path = File.join(dir, 'hosts')
      File.write(path, "127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n192.168.1.10 storage\n")

      described_class.new(path).set(OsCtl::Lib::Hostname.new('node.example.com'))

      expect(hosts(path)).to include("192.168.1.10 storage\n")
    end
  end

  it 'does not duplicate names already present' do
    with_tmpdir do |dir|
      path = File.join(dir, 'hosts')
      File.write(
        path,
        "127.0.0.1 node.example.com node localhost\n" \
        "::1 node.example.com node localhost ip6-localhost ip6-loopback\n"
      )

      described_class.new(path).set(OsCtl::Lib::Hostname.new('node.example.com'))

      expect(hosts(path)).to include("127.0.0.1 node.example.com node localhost\n")
      expect(hosts(path)).to include("::1 node.example.com node localhost ip6-localhost ip6-loopback\n")
    end
  end

  it 'replaces old names with new names on both localhost lines' do
    with_tmpdir do |dir|
      path = File.join(dir, 'hosts')
      File.write(
        path,
        "127.0.0.1 old.example.com old localhost\n" \
        "::1 old.example.com old localhost ip6-localhost ip6-loopback\n"
      )

      described_class.new(path).replace(
        OsCtl::Lib::Hostname.new('old.example.com'),
        OsCtl::Lib::Hostname.new('new.example.com')
      )

      content = hosts(path)

      expect(content).to include('127.0.0.1 new.example.com new localhost')
      expect(content).to include('::1 new.example.com new localhost ip6-localhost ip6-loopback')
      expect(content).not_to include('old.example.com')
    end
  end

  it 'handles fqdn and local-only replacements' do
    with_tmpdir do |dir|
      path = File.join(dir, 'hosts')
      File.write(
        path,
        "127.0.0.1 node localhost\n" \
        "::1 node localhost ip6-localhost ip6-loopback\n"
      )

      described_class.new(path).replace(
        OsCtl::Lib::Hostname.new('node'),
        OsCtl::Lib::Hostname.new('app.example.com')
      )

      expect(hosts(path)).to include('127.0.0.1 app.example.com app localhost')
      expect(hosts(path)).to include('::1 app.example.com app localhost ip6-localhost ip6-loopback')
    end
  end

  it 'removes only the generated notice block on unmanage' do
    with_tmpdir do |dir|
      path = File.join(dir, 'hosts')
      etc_hosts = described_class.new(path)

      etc_hosts.set(OsCtl::Lib::Hostname.new('node.example.com'))
      etc_hosts.unmanage

      expect(hosts(path)).not_to include(described_class::NOTICE_HEAD)
      expect(hosts(path)).to include('127.0.0.1 node.example.com node localhost')
    end
  end

  it 'keeps unrelated content when notice blocks are malformed' do
    with_tmpdir do |dir|
      path = File.join(dir, 'hosts')
      File.write(
        path,
        <<~HOSTS
          #{described_class::NOTICE_HEAD}
          # generated
          127.0.0.1 preserved localhost
          #{described_class::NOTICE_TAIL}
          192.168.1.10 storage
        HOSTS
      )

      described_class.new(path).unmanage

      expect(hosts(path)).to include('127.0.0.1 preserved localhost')
      expect(hosts(path)).to include('192.168.1.10 storage')
    end
  end
end
