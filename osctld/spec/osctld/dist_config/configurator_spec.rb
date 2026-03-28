# frozen_string_literal: true

# rubocop:disable RSpec/MultipleDescribes, RSpec/VerifiedDoubles

require 'ostruct'

require 'osctld/dist_config'
require 'osctld/dist_config/configurator'
require 'osctld/etc_hosts'

RSpec.describe OsCtld::DistConfig do
  describe '.run' do
    before do
      OsCtl::Lib::Logger.setup(:none)
    end

    let(:ctrc) do
      double(
        distribution: distribution,
        mount: nil,
        log: nil
      )
    end
    let(:distribution) { 'known' }

    it 'mounts for non-stop commands and dispatches to the configured class' do
      dist_instance = double(start: nil)
      dist_class = double(new: dist_instance)

      allow(described_class).to receive(:for).with(:known).and_return(dist_class)

      described_class.run(ctrc, :start)

      expect(ctrc).to have_received(:mount)
      expect(dist_class).to have_received(:new).with(ctrc)
      expect(dist_instance).to have_received(:start).with({})
    end

    it 'does not mount for stop commands' do
      dist_instance = double(stop: nil)
      dist_class = double(new: dist_instance)

      allow(described_class).to receive(:for).with(:known).and_return(dist_class)

      described_class.run(ctrc, :stop)

      expect(ctrc).not_to have_received(:mount)
      expect(dist_instance).to have_received(:stop).with({})
    end

    it 'falls back to :other for unknown distributions' do
      fallback = double(start: nil)
      fallback_class = double(new: fallback)

      allow(described_class).to receive(:for).with(:unknown).and_return(nil)
      allow(described_class).to receive(:for).with(:other).and_return(fallback_class)

      described_class.run(double(distribution: 'unknown', mount: nil, log: nil), :start)

      expect(fallback_class).to have_received(:new)
    end

    it 'logs and swallows exceptions from distribution commands' do
      dist_class = Class.new do
        def initialize(_ctrc); end

        def start(_opts)
          raise 'boom'
        end
      end

      allow(described_class).to receive(:for).with(:known).and_return(dist_class)
      allow(described_class).to receive(:denixstorify).and_return(['trace'])

      expect { described_class.run(ctrc, :start) }.not_to raise_error
      expect(ctrc).to have_received(:log).with(:warn, 'DistConfig.start failed: boom')
      expect(ctrc).to have_received(:log).with(:warn, 'trace')
    end
  end
end

RSpec.describe OsCtld::DistConfig::Configurator do
  before do
    OsCtl::Lib::Logger.setup(:none)
  end

  let(:network_backend_class) do
    Class.new do
      attr_reader :configurator

      def initialize(configurator)
        @configurator = configurator
      end

      def usable?
        true
      end
    end
  end

  let(:configurator_class) do
    backend = network_backend_class

    Class.new(described_class) do
      define_method(:set_hostname) { |_new_hostname, old_hostname: nil| [rootfs, old_hostname] }

      define_method(:network_class) do
        backend
      end
    end
  end

  let(:rootfs) { Dir.mktmpdir('dist-config-rootfs') }
  let(:configurator) { configurator_class.new('pool:ct1', rootfs, 'debian', '12') }
  let(:hostname_class) do
    Struct.new(:fqdn, :local, keyword_init: true)
  end

  after do
    FileUtils.rm_rf(rootfs)
  end

  it 'updates and replaces /etc/hosts entries' do
    FileUtils.mkdir_p(File.join(rootfs, 'etc'))
    hosts = File.join(rootfs, 'etc', 'hosts')
    File.write(hosts, "127.0.0.1 localhost\n::1 localhost\n")

    configurator.update_etc_hosts(hostname_class.new(fqdn: 'new.example', local: 'new'))
    expect(File.read(hosts)).to include('127.0.0.1 new.example new localhost')

    configurator.update_etc_hosts(
      hostname_class.new(fqdn: 'after.example', local: 'after'),
      old_hostname: hostname_class.new(fqdn: 'new.example', local: 'new')
    )

    content = File.read(hosts)
    expect(content).to include('127.0.0.1 after.example after localhost')
    expect(content).not_to include('new.example')
  end

  it 'unmanages /etc/hosts' do
    FileUtils.mkdir_p(File.join(rootfs, 'etc'))
    hosts = File.join(rootfs, 'etc', 'hosts')
    File.write(hosts, <<~HOSTS)
      #{OsCtld::EtcHosts::NOTICE_HEAD}
      # generated
      #{OsCtld::EtcHosts::NOTICE_TAIL}
      127.0.0.1 localhost
    HOSTS

    configurator.unset_etc_hosts

    expect(File.read(hosts)).to eq("127.0.0.1 localhost\n")
  end

  it 'writes resolv.conf content with the configured resolvers' do
    FileUtils.mkdir_p(File.join(rootfs, 'etc'))

    configurator.dns_resolvers(%w[1.1.1.1 8.8.8.8])

    expect(File.read(File.join(rootfs, 'etc', 'resolv.conf'))).to eq(
      "nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions edns0\n"
    )
  end

  it 'instantiates nil, single, first-usable, and no-usable network classes' do
    nil_configurator = Class.new(described_class) do
      def set_hostname(_new_hostname, old_hostname: nil); end

      def network_class
        nil
      end
    end.new('pool:ct1', rootfs, 'debian', '12')

    expect(nil_configurator.send(:network_backend)).to be_nil

    expect(configurator.send(:network_backend)).to be_a(network_backend_class)

    unusable = Class.new(network_backend_class) do
      def usable?
        false
      end
    end
    usable = network_backend_class
    multi_configurator = Class.new(described_class) do
      define_method(:set_hostname) { |_new_hostname, _old_hostname: nil| nil }
      define_method(:network_class) { [unusable, usable] }
    end.new('pool:ct1', rootfs, 'debian', '12')

    expect(multi_configurator.send(:network_backend)).to be_a(network_backend_class)

    no_usable_configurator = Class.new(described_class) do
      define_method(:set_hostname) { |_new_hostname, _old_hostname: nil| nil }
      define_method(:network_class) { [unusable] }
    end.new('pool:ct1', rootfs, 'debian', '12')

    expect(no_usable_configurator.send(:network_backend)).to be_nil
  end
end
# rubocop:enable RSpec/MultipleDescribes, RSpec/VerifiedDoubles
