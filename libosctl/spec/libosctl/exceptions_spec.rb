# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/exceptions'

RSpec.describe OsCtl::Lib::Exceptions do
  describe OsCtl::Lib::Exceptions::SystemCommandFailed do
    it 'stores the command context in attributes and message' do
      error = described_class.new('zfs list', 3, 'boom')

      expect(error.cmd).to eq('zfs list')
      expect(error.rc).to eq(3)
      expect(error.output).to eq('boom')
      expect(error.message).to include("command 'zfs list' exited with code '3'")
      expect(error.message).to include("output: 'boom'")
    end
  end

  describe OsCtl::Lib::Exceptions::OsProcessNotFound do
    it 'formats the process id in the error message' do
      expect(described_class.new(1234).message).to eq('process 1234 not found')
    end
  end

  describe OsCtl::Lib::Exceptions::IdMappingError do
    it 'includes the id map and the failing id in the error message' do
      idmap = instance_double(Object, to_s: '0:100000:65536')

      expect(described_class.new(idmap, 42).message).to eq(
        'unable to map id 42 using 0:100000:65536'
      )
    end
  end
end
