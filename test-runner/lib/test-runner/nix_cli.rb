require 'json'
require 'open3'

module TestRunner
  class NixCli
    DEFAULT_SYSTEM = 'x86_64-linux'.freeze

    attr_reader :system, :test_config_path, :repo_root

    def initialize(system: DEFAULT_SYSTEM, test_config_path: nil, repo_root: nil)
      @system = if system.nil? || system.empty?
                  DEFAULT_SYSTEM
                else
                  system
                end
      @repo_root = File.expand_path(repo_root || ENV['TEST_RUNNER_REPO_ROOT'] || Dir.pwd)
      @test_config_path =
        if test_config_path.nil? || test_config_path.empty?
          nil
        else
          File.expand_path(test_config_path, @repo_root)
        end
    end

    def eval_tests_meta_all
      capture_output(*eval_cmd(mode: 'testsMetaAll'))
    end

    def eval_test_meta(path)
      capture_output(*eval_cmd(mode: 'testsMetaOne', test_path: path))
    end

    def build_test_json(path, out_link, test_args: {})
      run!(*build_cmd(mode: 'testJson', test_path: path, test_args:, out_link: out_link))
    end

    def build_test_batch(selection, out_link, max_jobs:, log_path:)
      cmd = build_cmd(mode: 'testBatch', test_path: nil, test_args: nil, out_link:)
      cmd += ['--argstr', 'selectedTestsJson', JSON.generate(selection), '--max-jobs', max_jobs.to_s]
      run!(*cmd, log_path:)
    end

    def local_max_jobs
      config = JSON.parse(capture_output('nix', 'config', 'show', '--json'))
      value = config.fetch('max-jobs').fetch('value')
      # Nix normally serializes the resolved value even for max-jobs=auto.
      value = ResourcePool.detect_cpus if value == 'auto'
      jobs = Integer(value)
      raise ArgumentError, 'Nix max-jobs must be non-negative' if jobs < 0

      jobs
    end

    protected

    def helper_file
      File.expand_path('../../nix/evaluate-tests.nix', __dir__)
    end

    def eval_cmd(mode:, test_path: nil)
      base_cmd(
        'nix-instantiate',
        '--eval',
        '--strict',
        '--json',
        mode:,
        test_path:
      )
    end

    def build_cmd(mode:, test_path:, test_args:, out_link:)
      base_cmd(
        'nix-build',
        '--out-link',
        out_link,
        mode:,
        test_path:,
        test_args:
      )
    end

    def base_cmd(*cmd, mode:, test_path: nil, test_args: nil)
      ret = [
        *cmd,
        helper_file,
        '--arg',
        'repoRoot',
        repo_root,
        '--argstr',
        'system',
        system,
        '--argstr',
        'mode',
        mode
      ]

      ret += ['--arg', 'testConfigPath', test_config_path] if test_config_path
      ret += ['--argstr', 'testPath', test_path] if test_path
      ret += ['--argstr', 'testArgsJson', JSON.generate(test_args)] unless test_args.nil?
      ret
    end

    def capture_output(*cmd)
      out, status = Open3.capture2(*cmd)
      raise "#{cmd.join(' ')} failed (#{status_description(status)})" unless status.success?

      out
    end

    def run!(*cmd, log_path: nil)
      log = File.open(log_path, 'a') if log_path
      options = { pgroup: true }
      options.merge!(out: log, err: %i[child out]) if log
      pid = spawn(*cmd, **options)
      _pid, status = Process.wait2(pid)
      return if status.success?

      log&.puts("Preparation build failed (#{status_description(status)})")
      raise "#{cmd.join(' ')} failed (#{status_description(status)})"
    rescue SignalException => e
      if pid
        begin
          Process.kill(e.signo, -pid)
        rescue Errno::ESRCH
          # The owned client already exited.
        end
        begin
          Process.wait(pid)
        rescue Errno::ECHILD
          # Cancellation can arrive after wait2 has already reaped the client.
        end
      end
      log&.puts("Preparation interrupted by signal #{e.signo} (#{Signal.signame(e.signo)})")
      raise
    ensure
      log&.close
    end

    def status_description(status)
      return status.exitstatus.to_s unless status.signaled?

      "signal #{status.termsig} (#{Signal.signame(status.termsig)})"
    end
  end
end
