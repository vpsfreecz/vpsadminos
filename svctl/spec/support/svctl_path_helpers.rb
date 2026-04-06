# frozen_string_literal: true

module SvctlPathHelpers
  def with_svctl_paths
    with_tmpdir do |dir|
      runsvdir = File.join(dir, 'runsvdir')
      services = File.join(dir, 'services')
      protected = File.join(dir, 'protected-services.txt')

      FileUtils.mkdir_p(runsvdir)
      FileUtils.mkdir_p(services)

      stub_const('SvCtl::RUNSVDIR', runsvdir)
      stub_const('SvCtl::SERVICE_DIR', services)
      stub_const('SvCtl::PROTECTED_SERVICES_FILE', protected)

      yield(runsvdir:, services:, protected:)
    end
  end
end

RSpec.configure do |config|
  config.include SvctlPathHelpers
end
