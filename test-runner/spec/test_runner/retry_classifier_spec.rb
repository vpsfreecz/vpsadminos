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

  it 'classifies transient APK v2 failures' do
    {
      'temporary error (try again later)' => 'APK transient network failure',
      'operation timed out' => 'APK transport timeout',
      'network connection aborted' => 'APK transport failure',
      'could not connect to server (check repositories file)' => 'APK transport failure',
      'network error (check Internet connection and firewall)' => 'APK transport failure'
    }.each do |failure, reason|
      error = command_failed(<<~OUTPUT, status: 1)
        WARNING: updating https://apk.example.test/APKINDEX.tar.gz: #{failure}
        1 unavailable, 0 stale; 42 distinct packages available
      OUTPUT

      expect(described_class.apk(error)).to eq(reason)
    end
  end

  it 'classifies transient APK v3 failures' do
    {
      'DNS: transient error (try again later)' => 'APK transient network failure',
      'Connection timed out' => 'APK transport timeout',
      'Connection reset by peer' => 'APK transport failure',
      'HTTP 503: Service Unavailable' => 'APK repository HTTP failure'
    }.each do |failure, reason|
      error = command_failed(<<~OUTPUT, status: 1)
        WARNING: updating and opening https://apk.example.test/packages.adb: #{failure}
        ERROR: Not continuing due to stale/unavailable repositories. Use --force-missing-repositories to continue.
      OUTPUT

      expect(described_class.apk(error)).to eq(reason)
    end
  end

  it 'classifies a transient APK package download failure' do
    {
      'HTTP 504: Gateway Timeout' => 'APK repository HTTP failure',
      'Software caused connection abort' => 'APK transport failure'
    }.each do |failure, reason|
      error = command_failed(<<~OUTPUT, status: 1)
        ERROR: curl-8.14.1-r2: #{failure}
        1 error; 12 MiB in 25 packages
      OUTPUT

      expect(described_class.apk(error)).to eq(reason)
    end
  end

  it 'does not classify permanent APK failures' do
    [
      'HTTP 404: Not Found',
      'DNS: name does not exist',
      'DNS lookup error',
      'TLS: server certificate not trusted',
      'BAD signature',
      'invalid URL (check your repositories file)',
      'package mentioned in index not found (try apk update)',
      'remote server returned error (try apk update)'
    ].each do |failure|
      error = command_failed(<<~OUTPUT, status: 1)
        WARNING: updating https://apk.example.test/APKINDEX.tar.gz: #{failure}
        1 unavailable, 0 stale; 42 distinct packages available
      OUTPUT

      expect(described_class.apk(error)).to be_nil
    end
  end

  it 'does not classify an APK transport failure followed by a package error' do
    error = command_failed(<<~OUTPUT, status: 1)
      WARNING: updating https://apk.example.test/APKINDEX.tar.gz: temporary error (try again later)
      ERROR: unable to select packages:
        definitely-not-a-package (no such package)
      1 error; 12 MiB in 25 packages
    OUTPUT

    expect(described_class.apk(error)).to be_nil
  end

  it 'does not classify mixed transient and permanent APK repository failures' do
    error = command_failed(<<~OUTPUT, status: 1)
      WARNING: updating https://first.example.test/packages.adb: HTTP 503: Service Unavailable
      WARNING: updating https://second.example.test/packages.adb: HTTP 403: Forbidden
      2 unavailable, 0 stale; 42 distinct packages available
    OUTPUT

    expect(described_class.apk(error)).to be_nil
  end

  it 'does not classify an APK diagnostic without a terminal failure summary' do
    error = command_failed(<<~OUTPUT, status: 1)
      WARNING: updating https://apk.example.test/packages.adb: HTTP 503: Service Unavailable
      package setup failed after apk exited
    OUTPUT

    expect(described_class.apk(error)).to be_nil
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
    expect(described_class.apk(StandardError.new('temporary error (try again later)'))).to be_nil
    expect(described_class.guix_operation(StandardError.new('Git error: SSL error'))).to be_nil
    expect(described_class.guix_preparation(StandardError.new('SWH vault: Processing'))).to be_nil
  end
end
