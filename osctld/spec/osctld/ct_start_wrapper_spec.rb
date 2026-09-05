# frozen_string_literal: true

load File.expand_path('../../bin/osctld-ct-start', __dir__)

RSpec.describe OsCtldCtStart do
  def bootstrap(payload)
    reader, writer = IO.pipe
    writer.write(JSON.generate(payload))
    writer.close
    reader.autoclose = false

    described_class.load_bootstrap(reader.fileno.to_s)
  end

  it 'loads lifecycle credentials and descriptor numbers from the private channel' do
    expect(
      bootstrap(
        pool: 'tank',
        ctid: 'ct1',
        run_id: 'run-1',
        lifecycle_start_token: 'start-token',
        cgroup_fds: [50, 51]
      )
    ).to eq(
      pool: 'tank',
      ctid: 'ct1',
      run_id: 'run-1',
      lifecycle_start_token: 'start-token',
      cgroup_fds: [50, 51]
    )
  end

  it 'moves only the current process through every inherited cgroup hierarchy' do
    with_tmpdir do |dir|
      files = %w[cpu memory].map do |subsystem|
        path = File.join(dir, subsystem, 'cgroup.procs')
        FileUtils.mkdir_p(File.dirname(path))
        file = File.open(path, 'w')
        file.autoclose = false
        file
      end

      described_class.enter_cgroups(files.map(&:fileno))

      files.each do |file|
        expect(File.read(file.path)).to eq("0\n")
      end
    end
  end

  it 'rejects malformed bootstrap data and invalid migration descriptors' do
    expect do
      bootstrap(
        pool: 'tank',
        ctid: 'ct1',
        run_id: 'run-1',
        lifecycle_start_token: '',
        cgroup_fds: [50]
      )
    end.to raise_error(ArgumentError, 'invalid bootstrap payload')

    expect { described_class.enter_cgroups([]) }.to raise_error(ArgumentError)
    expect { described_class.enter_cgroups([2]) }.to raise_error(ArgumentError)
    expect { described_class.enter_cgroups([50, 50]) }.to raise_error(ArgumentError)
  end
end
