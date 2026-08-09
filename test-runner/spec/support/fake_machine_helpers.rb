# frozen_string_literal: true

class FakeMachine
  attr_reader :calls

  def initialize(running: true, can_execute: true, kernel_failed: false, kernel_failure_on_stop: false)
    @running = running
    @can_execute = can_execute
    @kernel_failed = kernel_failed
    @kernel_failure_on_stop = kernel_failure_on_stop
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
    @kernel_failed = true if @kernel_failure_on_stop
  end

  def kill
    calls << :kill
  end

  def kill_after_kernel_failure
    calls << :kill_after_kernel_failure
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

  def kernel_failed?
    @kernel_failed
  end

  def raise_if_kernel_failed!
    return unless kernel_failed?

    raise OsVm::KernelFailure.new(
      machine_name: 'fake',
      console_line: 'Oops: fake failure',
      console_log_path: '/tmp/fake-console.log'
    )
  end
end

module FakeMachineHelpers
  def build_fake_machine(running: true, can_execute: true, kernel_failed: false, kernel_failure_on_stop: false)
    FakeMachine.new(running:, can_execute:, kernel_failed:, kernel_failure_on_stop:)
  end
end

RSpec.configure do |config|
  config.include FakeMachineHelpers
end
