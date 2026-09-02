# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::RetryClassifier do
  def command_failed(output, status: 100)
    OsVm::CommandFailed.new(
      "Command 'upstream-operation' failed with status #{status}. Output:\n#{output}"
    )
  end

  it 'classifies an APT mirror synchronization race' do
    error = command_failed(<<~OUTPUT)
      Get:1 http://deb.example.test stable InRelease [48.1 kB]
      E: Failed to fetch http://deb.example.test/Packages.xz  File has unexpected size (42 != 41). Mirror sync in progress? [IP: 192.0.2.10 80]
      E: Some index files failed to download. They have been ignored, or old ones used instead.
    OUTPUT

    expect(described_class.apt(error)).to eq('APT mirror synchronization race')
  end

  it 'classifies other transient APT transport failures' do
    {
      'Temporary failure resolving deb.example.test' => 'APT transport failure',
      '502 Bad Gateway' => 'APT mirror HTTP failure',
      'TLS connection was non-properly terminated' => 'APT mirror TLS failure'
    }.each do |failure, reason|
      error = command_failed(<<~OUTPUT)
        E: Failed to fetch http://deb.example.test/Packages.xz  #{failure}
        E: Unable to fetch some archives, maybe run apt-get update or try with --fix-missing?
      OUTPUT

      expect(described_class.apt(error)).to eq(reason)
    end
  end

  it 'does not classify an APT failure followed by a missing package' do
    error = command_failed(<<~OUTPUT)
      E: Failed to fetch http://deb.example.test/Packages.xz  Temporary failure resolving deb.example.test
      E: Some index files failed to download. They have been ignored, or old ones used instead.
      E: Unable to locate package definitely-not-a-package
    OUTPUT

    expect(described_class.apt(error)).to be_nil
  end

  it 'does not classify an APT failure followed by a signature error' do
    error = command_failed(<<~OUTPUT)
      E: Failed to fetch http://deb.example.test/InRelease  503 Service Unavailable
      E: The repository 'http://deb.example.test stable InRelease' is not signed.
    OUTPUT

    expect(described_class.apt(error)).to be_nil
  end

  it 'does not classify a permanent APT fetch failure before a transient one' do
    error = command_failed(<<~OUTPUT)
      E: Failed to fetch http://deb.example.test/missing.deb  404 Not Found
      E: Failed to fetch http://deb.example.test/Packages.xz  Temporary failure resolving deb.example.test
      E: Unable to fetch some archives, maybe run apt-get update or try with --fix-missing?
    OUTPUT

    expect(described_class.apt(error)).to be_nil
  end

  it 'does not classify an APT error followed by a non-APT command failure' do
    error = command_failed(<<~OUTPUT)
      E: Failed to fetch http://deb.example.test/Packages.xz  Temporary failure resolving deb.example.test
      E: Some index files failed to download. They have been ignored, or old ones used instead.
      systemctl: failed to start documented.service
    OUTPUT

    expect(described_class.apt(error)).to be_nil
  end

  it 'classifies a terminal Guix substitute failure' do
    error = command_failed(<<~OUTPUT, status: 1)
      substitution of /gnu/store/example timed out after 3600 seconds of silence
      guix deploy: error: some substitutes for the outputs of derivation `/gnu/store/example.drv' failed (usually happens due to networking issues); try --fallback
      error: executed command failed
    OUTPUT

    expect(described_class.guix_operation(error)).to eq('transient Guix substitute failure')
  end

  it 'classifies a terminal Guix Git failure' do
    error = command_failed(<<~OUTPUT, status: 1)
      guix time-machine: error: Git error: Could not resolve host: git.example.test
      error: executed command failed
    OUTPUT

    expect(described_class.guix_operation(error)).to eq('transient Guix Git failure')
  end

  it 'does not classify a Guix warning before a configuration error' do
    error = command_failed(<<~OUTPUT, status: 1)
      guix time-machine: error: Git error: SSL error: connection reset
      guix system: error: failed to load operating system declaration
      error: executed command failed
    OUTPUT

    expect(described_class.guix_operation(error)).to be_nil
  end

  it 'classifies a terminal Software Heritage timeout' do
    error = command_failed(<<~OUTPUT, status: 124)
      SWH vault: requested bundle cooking; waiting...
      SWH vault: Processing...
      Terminated
      error: executed command failed
    OUTPUT

    expect(described_class.guix_preparation(error)).to eq('Software Heritage fallback stalled')
  end

  it 'does not classify old Software Heritage progress on timeout' do
    error = command_failed(<<~OUTPUT, status: 124)
      SWH vault: Processing...
      building /gnu/store/first.drv...
      building /gnu/store/second.drv...
      building /gnu/store/third.drv...
      Terminated
      error: executed command failed
    OUTPUT

    expect(described_class.guix_preparation(error)).to be_nil
  end

  it 'does not classify Software Heritage progress before a permanent Guix error' do
    error = command_failed(<<~OUTPUT, status: 124)
      SWH vault: Processing...
      guix time-machine: error: failed to load channel declaration
      Terminated
      error: executed command failed
    OUTPUT

    expect(described_class.guix_preparation(error)).to be_nil
  end

  it 'ignores unrelated exception classes' do
    expect(described_class.apt(StandardError.new('Temporary failure resolving host'))).to be_nil
    expect(described_class.guix_operation(StandardError.new('Git error: SSL error'))).to be_nil
    expect(described_class.guix_preparation(StandardError.new('SWH vault: Processing'))).to be_nil
  end
end
