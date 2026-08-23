# frozen_string_literal: true

load File.expand_path(
  '../../../os/modules/system/activation/switch-to-configuration.rb',
  __dir__
)

RSpec.describe OsctldRestart do
  let(:service_class) do
    Class.new do
      def stop; end

      def start; end

      def running? = false
    end
  end
  let(:service) { instance_spy(service_class) }
  let(:services) do
    instance_double(
      Services,
      osctld_restart: service,
      osctld_target: service
    )
  end

  def coordinator(status:, commands: {})
    klass = Class.new(described_class) do
      attr_accessor :test_status, :test_commands, :test_wait_service_down
      attr_reader :calls

      protected

      def osctl_json(*) = test_status

      def run_osctl(*args)
        @calls ||= []
        @calls << args
        result = test_commands.fetch(args, true)
        result.is_a?(Array) ? result.shift : result
      end

      def wait_service_down = test_wait_service_down
    end
    ret = klass.new(services, dry_run: false)
    ret.test_status = status
    ret.test_commands = commands
    ret.test_wait_service_down = true
    ret
  end

  it 'drains the old daemon before asking runit to stop it' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => false }
    )

    restart.prepare

    expect(restart.calls).to eq([%w[daemon prepare-stop]])
    expect(service).to have_received(:stop).once
  end

  it 'resumes admission and leaves the service running when drain fails' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => false },
      commands: { %w[daemon prepare-stop] => false }
    )

    expect { restart.prepare }.to raise_error(
      RuntimeError,
      'osctld lifecycle drain failed before activation'
    )
    expect(restart.calls).to eq(
      [%w[daemon prepare-stop], %w[daemon resume]]
    )
    expect(service).not_to have_received(:stop)
  end

  it 'refuses to use the new drain protocol with a legacy daemon' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true }
    )

    expect { restart.prepare }.to raise_error(
      RuntimeError,
      'running osctld requires the legacy runtime upgrade protocol'
    )
    expect(service).not_to have_received(:stop)
  end

  it 'starts the target daemon before waiting for readiness' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => false }
    )

    restart.start_and_wait

    expect(service).to have_received(:start).once
    expect(restart.calls).to eq([%w[daemon wait-ready --timeout 300]])
  end

  it 'restores the current service when it cannot stop before activation' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => false }
    )
    restart.test_wait_service_down = false

    expect { restart.prepare }.to raise_error(
      RuntimeError,
      'osctld supervisor did not stop within 60 seconds'
    )
    expect(service).to have_received(:start).once
    expect(restart.calls).to eq(
      [%w[daemon prepare-stop], %w[daemon resume]]
    )
  end

  describe Services do
    def service(name)
      service_class = Class.new do
        def name; end

        def skip?; end

        def start; end

        def stop; end
      end
      instance_spy(service_class, name:, skip?: false)
    end

    it 'defers a changed nodectld restart until osctld is ready' do
      services = described_class.allocate
      osctld = service('osctld')
      nodectld = service('nodectld')
      other = service('other')
      allow(services).to receive(:restart).and_return(
        [osctld, nodectld, other]
      )

      expect(services.restart_before_osctld).to eq([other])
      expect(services.deferred_restart_after_osctld).to eq([nodectld])
      expect(services.restart_after_osctld).to eq([nodectld, other])
    end
  end
end
