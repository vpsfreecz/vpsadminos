# frozen_string_literal: true

require 'open3'
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
  end
end
# rubocop:enable RSpec/DescribeClass
