# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/system_command_result'

RSpec.describe OsCtl::Lib::SystemCommandResult do
  it 'reports success and exposes exit status and output' do
    result = described_class.new(0, 'ok')

    expect(result).to be_success
    expect(result).not_to be_error
    expect(result.exitstatus).to eq(0)
    expect(result.output).to eq('ok')
  end

  it 'warns on deprecated hash-like access and returns the requested field' do
    result = described_class.new(1, 'error')

    stderr = capture_stderr do
      expect(result[:output]).to eq('error')
      expect(result[:exitstatus]).to eq(1)
    end

    expect(stderr).to include('deprecated')
    expect(stderr).to include('Caller backtrace:')
  end
end
