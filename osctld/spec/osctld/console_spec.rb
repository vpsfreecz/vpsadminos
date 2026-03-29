# frozen_string_literal: true

require 'osctld/console'

RSpec.describe OsCtld::Console do
  let(:instances) { [] }

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)

    container_class = Class.new do
      attr_reader :ct, :connect_calls, :client_calls, :close_calls

      def initialize(ct)
        @ct = ct
        @connect_calls = []
        @client_calls = []
        @close_calls = 0
      end

      def connect_tty0(pid, socket)
        @connect_calls << [pid, socket]
      end

      def add_client(n, io)
        @client_calls << [n, io]
      end

      def close_all
        @close_calls += 1
      end
    end

    allow(container_class).to receive(:new).and_wrap_original do |method, ct|
      instance = method.call(ct)
      instances << instance
      instance
    end
    stub_const('OsCtld::Console::Container', container_class)
    described_class.init
  end

  it 'caches console containers per pool and id' do
    pool1 = Struct.new(:name, :console_dir, keyword_init: true).new(name: 'tank', console_dir: '/tmp/a')
    pool2 = Struct.new(:name, :console_dir, keyword_init: true).new(name: 'pool2', console_dir: '/tmp/b')
    ct1 = Struct.new(:id, :pool, keyword_init: true).new(id: 'ct1', pool: pool1)
    ct2 = Struct.new(:id, :pool, keyword_init: true).new(id: 'ct1', pool: pool2)

    first = described_class.container(ct1)
    second = described_class.container(ct2)

    expect(second).not_to equal(first)
    expect(described_class.container(ct1)).to equal(first)
    expect(described_class.container(ct2)).to equal(second)
  end

  it 'builds socket paths from the pool console directory and container id' do
    pool = Struct.new(:name, :console_dir, keyword_init: true).new(name: 'tank', console_dir: '/run/osctl/console')
    ct = Struct.new(:id, :pool, keyword_init: true).new(id: 'ct1', pool: pool)

    expect(described_class.socket_path(ct)).to eq('/run/osctl/console/ct1/tty0.sock')
  end

  it 'delegates tty0 connections and clients to the cached container' do
    with_tmpdir do |tmpdir|
      pool = Struct.new(:name, :console_dir, keyword_init: true).new(name: 'tank', console_dir: tmpdir)
      ct = Struct.new(:id, :pool, keyword_init: true).new(id: 'ct1', pool: pool)
      io = StringIO.new

      FileUtils.mkdir_p(File.dirname(described_class.socket_path(ct)))
      File.write(described_class.socket_path(ct), '')

      described_class.connect_tty0(ct, 101)
      described_class.client(ct, 2, io)
      described_class.reconnect_tty0(ct)

      container = described_class.container(ct)
      expect(container.connect_calls).to eq([
                                              [101, File.join(tmpdir, 'ct1', 'tty0.sock')],
                                              [nil, File.join(tmpdir, 'ct1', 'tty0.sock')]
                                            ])
      expect(container.client_calls).to eq([[2, io]])
    end
  end

  it 'removes only the matching pool/container entry and closes it once' do
    pool1 = Struct.new(:name, :console_dir, keyword_init: true).new(name: 'tank', console_dir: '/tmp/a')
    pool2 = Struct.new(:name, :console_dir, keyword_init: true).new(name: 'pool2', console_dir: '/tmp/b')
    ct1 = Struct.new(:id, :pool, keyword_init: true).new(id: 'ct1', pool: pool1)
    ct2 = Struct.new(:id, :pool, keyword_init: true).new(id: 'ct1', pool: pool2)
    first = described_class.container(ct1)
    second = described_class.container(ct2)

    described_class.remove(ct1)

    expect(first.close_calls).to eq(1)
    expect(second.close_calls).to eq(0)
    expect(described_class.container(ct2)).to equal(second)
    expect(described_class.container(ct1)).not_to equal(first)
  end
end
