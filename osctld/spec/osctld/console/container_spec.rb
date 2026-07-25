# frozen_string_literal: true

require 'osctld/console'
require 'osctld/console/container'
require 'osctld/container/run_configuration'

RSpec.describe OsCtld::Console::Container do
  let(:ct) { Struct.new(:id).new('ct1') }
  let(:console_instances) { [] }
  let(:tty_instances) { [] }

  before do
    console_class = Class.new do
      attr_reader :ct, :n, :clients, :connect_calls, :start_calls, :close_calls

      def initialize(ct, n)
        @ct = ct
        @n = n
        @clients = []
        @connect_calls = []
        @start_calls = 0
        @close_calls = 0
      end

      def start
        @start_calls += 1
      end

      def add_client(io)
        @clients << io
      end

      def connect(pid, socket, run_conf)
        @connect_calls << [pid, socket, run_conf]
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
    run_conf = instance_double(OsCtld::Container::RunConfiguration)

    container.connect_tty0(101, '/tmp/tty0.sock', run_conf)

    expect(console_instances.first.connect_calls).to eq(
      [[101, '/tmp/tty0.sock', run_conf]]
    )
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
