# frozen_string_literal: true

require 'osctl/repo'
require 'osctl/repo/cli'

RSpec.describe OsCtl::Repo::Cli::Command do
  def build_command(&)
    Class.new(described_class) do
      define_method(:call_target, &)
    end
  end

  it 'instantiates the command and dispatches to the target method' do
    klass = build_command { [gopts, opts, args] }
    runner = described_class.run(klass, :call_target)

    expect(runner.call({ verbose: true }, { cache: '/tmp/cache' }, %w[arg1 arg2])).to eq(
      [{ verbose: true }, { cache: '/tmp/cache' }, %w[arg1 arg2]]
    )
  end

  it 'maps image-not-found to the repository exit code' do
    image = instance_double(Object, to_s: 'alpine')
    klass = build_command { raise OsCtl::Repo::ImageNotFound, image }
    runner = described_class.run(klass, :call_target)

    expect { runner.call({}, {}, []) }
      .to raise_error(GLI::CustomExit) { |e| expect(e.exit_code).to eq(OsCtl::Repo::EXIT_IMAGE_NOT_FOUND) }
  end

  it 'maps format-not-found to the repository exit code' do
    image = instance_double(Object, to_s: 'alpine')
    klass = build_command { raise OsCtl::Repo::FormatNotFound.new(image, 'zfs') }
    runner = described_class.run(klass, :call_target)

    expect { runner.call({}, {}, []) }
      .to raise_error(GLI::CustomExit) { |e| expect(e.exit_code).to eq(OsCtl::Repo::EXIT_FORMAT_NOT_FOUND) }
  end

  it 'maps bad http responses to the repository exit code' do
    klass = build_command { raise OsCtl::Repo::BadHttpResponse, 503 }
    runner = described_class.run(klass, :call_target)

    expect { runner.call({}, {}, []) }
      .to raise_error(GLI::CustomExit) { |e| expect(e.exit_code).to eq(OsCtl::Repo::EXIT_HTTP_ERROR) }
  end

  it 'maps network errors to the repository exit code' do
    klass = build_command { raise OsCtl::Repo::NetworkError, SocketError.new('boom') }
    runner = described_class.run(klass, :call_target)

    expect { runner.call({}, {}, []) }
      .to raise_error(GLI::CustomExit) { |e| expect(e.exit_code).to eq(OsCtl::Repo::EXIT_NETWORK_ERROR) }
  end

  it 'does not swallow unrelated exceptions' do
    klass = build_command { raise ArgumentError, 'boom' }
    runner = described_class.run(klass, :call_target)

    expect { runner.call({}, {}, []) }.to raise_error(ArgumentError, 'boom')
  end
end
