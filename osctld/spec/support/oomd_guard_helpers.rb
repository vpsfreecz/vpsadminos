require 'osctld/manipulable'

module OomdGuardHelpers
  class GuardContainer
    include OsCtld::Manipulable
    attr_accessor :run_conf, :init_pid, :pool

    def id = 'ct1'
    def state = :running
    def running? = false
    def ephemeral? = false
    def get_exit_promise = nil
    def get_run_conf = run_conf
    def log(*) = nil

    def initialize(run_conf)
      init_manipulable
      @run_conf = run_conf
      @init_pid = 42
    end

    def manipulation_resource = %w[container tank:ct1]
  end

  class GuardPlan
    def stop_ct(_ct); end
  end
end
