# frozen_string_literal: true

require 'osctld/console'
require 'osctld/console/container'

RSpec.describe OsCtld::Console::Container do
  let(:ct) { Struct.new(:id).new('ct1') }
  let(:console_instances) { [] }
  let(:tty_instances) { [] }

  before do
    console_class = Class.new do
      attr_reader :ct, :n, :clients, :connect_calls, :attach_calls, :start_calls,
                  :close_calls

      def initialize(ct, n)
        @ct = ct
        @n = n
        @clients = []
        @connect_calls = []
        @attach_calls = []
        @start_calls = 0
        @close_calls = 0
      end

      def start
        @start_calls += 1
      end

      def add_client(io)
        @clients << io
      end

      def connect(pid, socket, run_conf, retry_limit: nil)
        @connect_calls << [pid, socket, run_conf, retry_limit]
      end

      def attach(pid, io, run_conf, ready: true)
        @attach_calls << [pid, io, run_conf, ready]
      end

      def activate(run_conf)
        @attach_calls << [:activate, run_conf]
        true
      end

      def close
        @close_calls += 1
      end
    end

    tty_class = Class.new(console_class)

    allow(console_class).to receive(:new).and_wrap_original do |method, *args|
      instance = method.call(*args)
      console_instances << instance
      instance
    end
    allow(tty_class).to receive(:new).and_wrap_original do |method, *args|
      instance = method.call(*args)
      tty_instances << instance
      instance
    end

    stub_const('OsCtld::Console::Console', console_class)
    stub_const('OsCtld::Console::TTY', tty_class)
  end

  it 'uses Console for tty0 and TTY for other tty numbers' do
    container = described_class.new(ct)

    expect(container.tty(0)).to equal(console_instances.first)
    expect(container.tty(1)).to equal(tty_instances.first)
    expect(console_instances.first.start_calls).to eq(1)
    expect(tty_instances.first.start_calls).to eq(1)
  end

  it 'caches tty instances by tty number' do
    container = described_class.new(ct)

    expect(container.tty(1)).to equal(container.tty(1))
    expect(tty_instances.size).to eq(1)
  end

  it 'delegates tty0 connections through tty 0' do
    container = described_class.new(ct)
    run_conf = Object.new

    container.connect_tty0(101, '/tmp/tty0.sock', run_conf)

    expect(console_instances.first.connect_calls).to eq([
                                                          [101, '/tmp/tty0.sock', run_conf, nil]
                                                        ])
  end

  it 'reconnects tty0 without a timing retry loop' do
    container = described_class.new(ct)
    run_conf = Object.new

    container.reconnect_tty0('/tmp/tty0.sock', run_conf)

    expect(console_instances.first.connect_calls).to eq([
                                                          [nil, '/tmp/tty0.sock', run_conf, 0]
                                                        ])
  end

  it 'delegates preconnected tty0 sockets through tty 0' do
    container = described_class.new(ct)
    run_conf = Object.new
    io = StringIO.new

    container.attach_tty0(nil, io, run_conf, ready: false)
    expect(container.activate_tty0(run_conf)).to be(true)

    expect(console_instances.first.attach_calls).to eq([
                                                         [nil, io, run_conf, false],
                                                         [:activate, run_conf]
                                                       ])
  end

  it 'closes every opened tty' do
    container = described_class.new(ct)
    tty0 = container.tty(0)
    tty1 = container.tty(1)

    container.close_all

    expect(tty0.close_calls).to eq(1)
    expect(tty1.close_calls).to eq(1)
  end
end
