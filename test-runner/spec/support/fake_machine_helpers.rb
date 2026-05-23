# frozen_string_literal: true

class FakeMachine
  attr_reader :calls

  def initialize(running: true, can_execute: true)
    @running = running
    @can_execute = can_execute
    @calls = []
  end

  def start(**_opts)
    calls << :start
  end

  def wait_for_boot
    calls << :wait_for_boot
  end

  def stop
    calls << :stop
  end

  def kill
    calls << :kill
  end

  def destroy
    calls << :destroy
  end

  def finalize
    calls << :finalize
  end

  def cleanup
    calls << :cleanup
  end

  def running?
    @running
  end

  def can_execute?
    @can_execute
  end
end

module FakeMachineHelpers
  def build_fake_machine(running: true, can_execute: true)
    FakeMachine.new(running:, can_execute:)
  end
end

RSpec.configure do |config|
  config.include FakeMachineHelpers
end
