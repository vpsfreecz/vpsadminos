# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::TestState do
  it 'uses the same identity for every script of a test' do
    test = build_test(path: 'driver/example', scripts: { 'first' => {}, 'second' => {} })
    paths = test.test_scripts.values.map { |script| described_class.directory('/state', script.test) }
    expect(paths.uniq.length).to eq(1)
    expect(paths.first).to match(%r{\A/state/os-test-driver__example-[a-f0-9]{8}\z})
  end

  it 'does not collide when test paths have the same escaped form' do
    paths = ['suite/a', 'suite__a'].map { |path| described_class.directory('/state', build_test(path:)) }
    expect(paths.uniq.length).to eq(2)
  end

  it 'refuses competing access and releases the lock after an error' do
    Dir.mktmpdir do |dir|
      marker = File.join(dir, 'retained.img')
      File.write(marker, 'retained')
      expect do
        described_class.with_lock(dir) do
          expect do
            described_class.with_lock(dir) { File.unlink(marker) }
          end.to raise_error(RuntimeError, /already in use/)
          raise 'interrupted'
        end
      end.to raise_error(RuntimeError, 'interrupted')
      described_class.with_lock(dir) { expect(File.read(marker)).to eq('retained') }
    end
  end

  it 'keeps its own state locked and releases unrelated worker locks when the parent finishes' do
    Dir.mktmpdir do |dir|
      own_dir = File.join(dir, 'own')
      other_dir = File.join(dir, 'other')
      ready_r, ready_w = IO.pipe
      finish_r, finish_w = IO.pipe
      pid = nil
      described_class.with_lock(other_dir) do
        described_class.with_lock(own_dir) do |state_lock|
          pid = described_class.fork(keep: state_lock) do
            ready_r.close
            finish_w.close
            ready_w.write('ready')
            ready_w.close
            finish_r.read
          end
          ready_w.close
          finish_r.close
          expect(ready_r.read).to eq('ready')
        end
      end
      described_class.with_lock(other_dir) { expect(Process.waitpid(pid, Process::WNOHANG)).to be_nil }
      expect do
        described_class.with_lock(own_dir) { raise 'acquired an active child state' }
      end.to raise_error(RuntimeError, /already in use/)
      finish_w.close
      Process.waitpid(pid)
      pid = nil
      described_class.with_lock(own_dir) { |lock| expect(lock).not_to be_closed }
    ensure
      finish_w&.close
      Process.waitpid(pid) if pid
      ready_r&.close
    end
  end
end
