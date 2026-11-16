# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'securerandom'
require 'spec_helper'

# These examples exercise action shell scripts, not a Ruby class.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'GitHub test state actions' do
  let(:repository_id) { '123' }
  let(:run_id) { '456' }
  let(:run_attempt) { '2' }

  def action_script(action, script)
    File.join(REPO_ROOT, '.github', 'actions', action, script)
  end

  def run_script(script, env)
    Open3.capture3(env, 'bash', script)
  end

  def state_directory(root)
    File.join(root, "os-test-runner-#{repository_id}-#{run_id}-#{run_attempt}")
  end

  def identifiers
    {
      'TEST_STATE_REPOSITORY_ID' => repository_id,
      'TEST_STATE_RUN_ID' => run_id,
      'TEST_STATE_RUN_ATTEMPT' => run_attempt
    }
  end

  def process_script
    File.join(REPO_ROOT, '.github', 'actions', 'test-state-processes.bash')
  end

  def process_identity(repository: repository_id, run: run_id, attempt: run_attempt, tracking: 'tracking-id')
    {
      'GITHUB_REPOSITORY_ID' => repository,
      'GITHUB_RUN_ID' => run,
      'GITHUB_RUN_ATTEMPT' => attempt,
      'RUNNER_TRACKING_ID' => tracking
    }
  end

  def fixture_program
    <<~RUBY
      File.write(ENV.fetch('FIXTURE_READY'), Process.pid.to_s)
      Signal.trap('TERM') { exit }
      sleep
    RUBY
  end

  def fixture_executable(root, name)
    bin_dir = File.join(root, 'fixture-bin')
    FileUtils.mkdir_p(bin_dir)
    path = File.join(bin_dir, name)

    unless File.exist?(path)
      FileUtils.cp(RbConfig.ruby, path)
      FileUtils.chmod(0o700, path)
    end

    path
  end

  def spawn_fixture(root:, executable:, argv:, identity: process_identity)
    ready = File.join(root, "ready-#{SecureRandom.hex(8)}")
    path = fixture_executable(root, executable)
    pid = Process.spawn(
      identity.merge('FIXTURE_READY' => ready),
      path,
      '-e',
      fixture_program,
      '--',
      *argv,
      in: File::NULL,
      out: File::NULL,
      err: File::NULL
    )
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5

    until File.exist?(ready)
      exited = Process.waitpid(pid, Process::WNOHANG)
      raise "fixture process #{pid} exited during startup" if exited
      raise "fixture process #{pid} did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep(0.01)
    end

    pid
  end

  def with_fixture_processes(*specifications)
    pids = []
    # Keep the partial list so ensure can join earlier children if a later
    # fixture fails to start.
    # rubocop:disable Style/MapIntoArray
    specifications.each do |specification|
      pids << spawn_fixture(**specification)
    end
    # rubocop:enable Style/MapIntoArray

    yield pids
  ensure
    pids&.each do |pid|
      Process.kill('TERM', pid)
    rescue Errno::ESRCH
      nil
    end
    pids&.each do |pid|
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def prepare_env(root)
    identifiers.merge(
      'TEST_STATE_ROOT' => root,
      'GITHUB_ENV' => File.join(root, 'github-env'),
      'GITHUB_OUTPUT' => File.join(root, 'github-output')
    )
  end

  def qemu_argv(directory)
    [
      '-chardev',
      "socket,id=shell,path=#{directory}/socks/machine-shell.sock"
    ]
  end

  def virtiofs_supervisor_argv(directory)
    [
      '--socket-path',
      "#{directory}/socks/machine-fs-shared.sock",
      '--shared-dir',
      "#{directory}/shared"
    ]
  end

  def virtiofs_worker_argv(directory)
    [
      "--socket-path=#{directory}/socks/machine-fs-worker.sock",
      "--shared-dir=#{directory}/shared-worker"
    ]
  end

  describe 'prepare-test-state' do
    let(:script) do
      action_script(
        'prepare-test-state',
        'prepare-test-state.bash'
      )
    end

    it 'replaces stale state and exports the isolated directory' do
      Dir.mktmpdir do |root|
        directory = state_directory(root)
        env_file = File.join(root, 'github-env')
        output_file = File.join(root, 'github-output')

        FileUtils.mkdir_p(directory)
        File.write(File.join(directory, 'stale.log'), 'stale')

        _stdout, stderr, status = run_script(
          script,
          identifiers.merge(
            'TEST_STATE_ROOT' => root,
            'GITHUB_ENV' => env_file,
            'GITHUB_OUTPUT' => output_file
          )
        )

        expect(status).to be_success
        expect(stderr).to be_empty
        expect(Dir.children(directory)).to be_empty
        expect(File.read(env_file)).to eq(
          "TEST_RUNNER_STATE_DIR=#{directory}\n"
        )
        expect(File.read(output_file)).to eq(
          "state-directory=#{directory}\n"
        )
      end
    end

    it 'rejects non-numeric GitHub identifiers before deleting state' do
      Dir.mktmpdir do |root|
        stale_directory = state_directory(root)
        FileUtils.mkdir_p(stale_directory)
        stale_file = File.join(stale_directory, 'stale.log')
        File.write(stale_file, 'stale')

        _stdout, _stderr, status = run_script(
          script,
          identifiers.merge(
            'TEST_STATE_RUN_ID' => '../unexpected',
            'TEST_STATE_ROOT' => root,
            'GITHUB_ENV' => File.join(root, 'github-env'),
            'GITHUB_OUTPUT' => File.join(root, 'github-output')
          )
        )

        expect(status).not_to be_success
        expect(File).to exist(stale_file)
      end
    end

    it 'refuses prior owned QEMU and virtiofs processes before replacing state' do
      Dir.mktmpdir do |root|
        current_directory = state_directory(root)
        prior_directory = File.join(root, "os-test-runner-#{repository_id}-455-1")
        stale_file = File.join(current_directory, 'stale.log')
        FileUtils.mkdir_p(current_directory)
        File.write(stale_file, 'stale')
        prior_identity = process_identity(run: '455', attempt: '1')
        fixtures = [
          {
            root: root,
            executable: 'qemu-kvm',
            argv: qemu_argv(prior_directory),
            identity: prior_identity
          },
          {
            root: root,
            executable: 'virtiofsd',
            argv: virtiofs_supervisor_argv(prior_directory),
            identity: prior_identity
          },
          {
            root: root,
            executable: 'virtiofsd',
            argv: virtiofs_worker_argv(prior_directory),
            identity: prior_identity
          }
        ]

        with_fixture_processes(*fixtures) do |pids|
          stdout, stderr, status = run_script(script, prepare_env(root))

          expect(status).not_to be_success
          expect(stderr).to be_empty
          expect(File).to exist(stale_file)
          pids.each do |pid|
            expect(stdout).to include("pid=#{pid} ")
            expect(process_alive?(pid)).to be(true)
          end
        end
      end
    end

    {
      'wrong repository' => { 'GITHUB_REPOSITORY_ID' => '999' },
      'wrong run' => { 'GITHUB_RUN_ID' => '999' },
      'wrong attempt' => { 'GITHUB_RUN_ATTEMPT' => '999' },
      'malformed repository identity' => { 'GITHUB_REPOSITORY_ID' => '123x' },
      'missing tracking ID' => { 'RUNNER_TRACKING_ID' => nil }
    }.each do |description, identity_change|
      it "refuses an unowned canonical process with #{description}" do
        Dir.mktmpdir do |root|
          directory = state_directory(root)
          stale_file = File.join(directory, 'stale.log')
          FileUtils.mkdir_p(directory)
          File.write(stale_file, 'stale')
          identity = process_identity.merge(identity_change)

          with_fixture_processes(
            root: root,
            executable: 'qemu-system-x86_64',
            argv: qemu_argv(directory),
            identity: identity
          ) do |pids|
            stdout, _stderr, status = run_script(script, prepare_env(root))

            expect(status).not_to be_success
            expect(stdout).to include("pid=#{pids.fetch(0)} ")
            expect(File).to exist(stale_file)
            expect(process_alive?(pids.fetch(0))).to be(true)
          end
        end
      end
    end

    it 'refuses an ambiguous process referencing two canonical states' do
      Dir.mktmpdir do |root|
        directory = state_directory(root)
        prior_directory = File.join(root, "os-test-runner-#{repository_id}-455-1")
        stale_file = File.join(directory, 'stale.log')
        FileUtils.mkdir_p(directory)
        File.write(stale_file, 'stale')
        argv = qemu_argv(directory) + [
          '-drive',
          "file=#{prior_directory}/machine.img,format=raw"
        ]

        with_fixture_processes(
          root: root,
          executable: 'qemu-kvm',
          argv: argv,
          identity: process_identity
        ) do |pids|
          stdout, _stderr, status = run_script(script, prepare_env(root))

          expect(status).not_to be_success
          expect(stdout).to include("pid=#{pids.fetch(0)} ")
          expect(stdout).to include('state=<ambiguous>')
          expect(File).to exist(stale_file)
          expect(process_alive?(pids.fetch(0))).to be(true)
        end
      end
    end

    {
      'wrong executable' => :wrong_executable,
      'another state root' => :another_root,
      'an unrelated livepatch namespace' => :livepatch,
      'another repository with complete ownership' => :other_repository
    }.each do |description, fixture_type|
      it "does not adopt #{description}" do
        Dir.mktmpdir do |root|
          directory = state_directory(root)
          stale_file = File.join(directory, 'stale.log')
          FileUtils.mkdir_p(directory)
          File.write(stale_file, 'stale')
          fixture = case fixture_type
                    when :wrong_executable
                      {
                        root: root,
                        executable: 'unrelated-vm',
                        argv: qemu_argv(directory),
                        identity: process_identity
                      }
                    when :another_root
                      other = File.join(Dir.tmpdir, "other-test-state-#{SecureRandom.hex(8)}")
                      state = File.join(
                        other,
                        "os-test-runner-#{repository_id}-#{run_id}-#{run_attempt}"
                      )
                      {
                        root: root,
                        executable: 'qemu-kvm',
                        argv: qemu_argv(state),
                        identity: process_identity
                      }
                    when :livepatch
                      {
                        root: root,
                        executable: 'qemu-kvm',
                        argv: qemu_argv('/run/github-runner/runner/_temp/lp-123-456-1'),
                        identity: process_identity
                      }
                    when :other_repository
                      other = File.join(root, 'os-test-runner-999-1000-1')
                      {
                        root: root,
                        executable: 'qemu-kvm',
                        argv: qemu_argv(other),
                        identity: process_identity(repository: '999', run: '1000', attempt: '1')
                      }
                    end

          with_fixture_processes(fixture) do |pids|
            _stdout, stderr, status = run_script(script, prepare_env(root))

            expect(status).to be_success
            expect(stderr).to be_empty
            expect(File).not_to exist(stale_file)
            expect(process_alive?(pids.fetch(0))).to be(true)
          end
        end
      end
    end

    {
      'a traversal reference' => lambda do |directory|
        "#{directory}/../escaped/socks/machine-shell.sock"
      end,
      'a state-directory prefix collision' => lambda do |directory|
        "#{directory}-other/socks/machine-shell.sock"
      end
    }.each do |description, path_builder|
      it "refuses #{description} without adopting it" do
        Dir.mktmpdir do |root|
          directory = state_directory(root)
          stale_file = File.join(directory, 'stale.log')
          FileUtils.mkdir_p(directory)
          File.write(stale_file, 'stale')

          with_fixture_processes(
            root: root,
            executable: 'qemu-kvm',
            argv: ['-drive', "file=#{path_builder.call(directory)},format=raw"],
            identity: process_identity
          ) do |pids|
            stdout, _stderr, status = run_script(script, prepare_env(root))

            expect(status).not_to be_success
            expect(stdout).to include("pid=#{pids.fetch(0)} ")
            expect(File).to exist(stale_file)
            expect(process_alive?(pids.fetch(0))).to be(true)
          end
        end
      end
    end

    it 'treats a process that exited before the scan as absent' do
      Dir.mktmpdir do |root|
        directory = state_directory(root)
        path = fixture_executable(root, 'qemu-kvm')
        pid = Process.spawn(
          process_identity,
          path,
          '-e',
          'exit',
          '--',
          *qemu_argv(directory),
          in: File::NULL,
          out: File::NULL,
          err: File::NULL
        )
        Process.wait(pid)

        _stdout, stderr, status = run_script(script, prepare_env(root))

        expect(status).to be_success
        expect(stderr).to be_empty
        expect(File).to be_directory(directory)
      end
    end
  end

  describe 'cleanup-test-state' do
    let(:script) do
      action_script(
        'cleanup-test-state',
        'cleanup-test-state.bash'
      )
    end

    def cleanup_env(root, test_outcome:, upload_outcome:)
      identifiers.merge(
        'TEST_STATE_ROOT' => root,
        'TEST_STATE_DIRECTORY' => state_directory(root),
        'TEST_STATE_PREPARE_OUTCOME' => 'success',
        'TEST_STATE_TEST_OUTCOME' => test_outcome,
        'TEST_STATE_UPLOAD_OUTCOME' => upload_outcome
      )
    end

    where_cleanup_is_expected = [
      %w[success skipped],
      %w[skipped skipped],
      %w[failure success],
      %w[cancelled success]
    ]

    where_cleanup_is_expected.each do |test_outcome, upload_outcome|
      it "cleans state after #{test_outcome}/#{upload_outcome}" do
        Dir.mktmpdir do |root|
          directory = state_directory(root)
          FileUtils.mkdir_p(directory)

          _stdout, stderr, status = run_script(
            script,
            cleanup_env(
              root,
              test_outcome: test_outcome,
              upload_outcome: upload_outcome
            )
          )

          expect(status).to be_success
          expect(stderr).to be_empty
          expect(File).not_to exist(directory)
        end
      end
    end

    where_preservation_is_expected = [
      %w[failure failure],
      %w[failure skipped],
      %w[cancelled failure]
    ]

    where_preservation_is_expected.each do |test_outcome, upload_outcome|
      it "preserves state after #{test_outcome}/#{upload_outcome}" do
        Dir.mktmpdir do |root|
          directory = state_directory(root)
          FileUtils.mkdir_p(directory)

          _stdout, stderr, status = run_script(
            script,
            cleanup_env(
              root,
              test_outcome: test_outcome,
              upload_outcome: upload_outcome
            )
          )

          expect(status).to be_success
          expect(stderr).to be_empty
          expect(File).to exist(directory)
        end
      end
    end

    it 'does nothing when preparation did not succeed' do
      Dir.mktmpdir do |root|
        directory = state_directory(root)
        FileUtils.mkdir_p(directory)

        env = cleanup_env(
          root,
          test_outcome: 'skipped',
          upload_outcome: 'skipped'
        ).merge('TEST_STATE_PREPARE_OUTCOME' => 'failure')

        _stdout, stderr, status = run_script(script, env)

        expect(status).to be_success
        expect(stderr).to be_empty
        expect(File).to exist(directory)
      end
    end

    it 'refuses to delete a directory not owned by this workflow attempt' do
      Dir.mktmpdir do |root|
        unexpected_directory = File.join(root, 'unexpected')
        FileUtils.mkdir_p(unexpected_directory)

        env = cleanup_env(
          root,
          test_outcome: 'success',
          upload_outcome: 'skipped'
        ).merge('TEST_STATE_DIRECTORY' => unexpected_directory)

        _stdout, _stderr, status = run_script(script, env)

        expect(status).not_to be_success
        expect(File).to exist(unexpected_directory)
      end
    end

    it 'preserves current state while an exactly owned process remains' do
      Dir.mktmpdir do |root|
        directory = state_directory(root)
        sentinel = File.join(directory, 'result.log')
        FileUtils.mkdir_p(directory)
        File.write(sentinel, 'result')

        with_fixture_processes(
          root: root,
          executable: 'qemu-kvm',
          argv: qemu_argv(directory),
          identity: process_identity
        ) do |pids|
          stdout, stderr, status = run_script(
            script,
            cleanup_env(
              root,
              test_outcome: 'success',
              upload_outcome: 'skipped'
            )
          )

          expect(status).not_to be_success
          expect(stderr).to be_empty
          expect(stdout).to include("pid=#{pids.fetch(0)} ")
          expect(File).to exist(sentinel)
          expect(process_alive?(pids.fetch(0))).to be(true)
        end
      end
    end

    it 'preserves current state for an unresolved current process' do
      Dir.mktmpdir do |root|
        directory = state_directory(root)
        sentinel = File.join(directory, 'result.log')
        FileUtils.mkdir_p(directory)
        File.write(sentinel, 'result')

        with_fixture_processes(
          root: root,
          executable: 'virtiofsd',
          argv: virtiofs_supervisor_argv(directory),
          identity: process_identity.merge('RUNNER_TRACKING_ID' => nil)
        ) do |pids|
          stdout, _stderr, status = run_script(
            script,
            cleanup_env(
              root,
              test_outcome: 'success',
              upload_outcome: 'skipped'
            )
          )

          expect(status).not_to be_success
          expect(stdout).to include("pid=#{pids.fetch(0)} ")
          expect(File).to exist(sentinel)
          expect(process_alive?(pids.fetch(0))).to be(true)
        end
      end
    end
  end

  it 'keeps same-UID and stable start-time admission in the shared guard' do
    source = File.read(process_script)

    expect(source).to include('effective_uid" == "$EUID')
    expect(source).to include('final_start_time" == "$start_time')
  end
end
# rubocop:enable RSpec/DescribeClass
