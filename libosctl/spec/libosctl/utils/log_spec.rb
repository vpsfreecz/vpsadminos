# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/logger'
require 'libosctl/utils/log'

RSpec.describe OsCtl::Lib::Utils::Log do
  let(:helper_class) do
    Class.new do
      include OsCtl::Lib::Utils::Log

      def log_type
        'custom'
      end
    end
  end

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  it 'adds instance and class log methods and resolves levels and types' do
    helper = helper_class.new

    helper.log('one argument')
    helper.log(:warn, 'two arguments')
    helper.log(:error, :explicit, 'three arguments')
    helper.log(:bogus, :explicit, 'unknown level')
    helper_class.log(:info, :class_type, 'class method')

    expect(OsCtl::Lib::Logger).to have_received(:log).with(:info, '[general] one argument')
    expect(OsCtl::Lib::Logger).to have_received(:log).with(:warn, '[custom] two arguments')
    expect(OsCtl::Lib::Logger).to have_received(:log).with(:error, '[explicit] three arguments')
    expect(OsCtl::Lib::Logger).to have_received(:log).with(:unknown, '[explicit] unknown level')
    expect(OsCtl::Lib::Logger).to have_received(:log).with(:info, '[class_type] class method')
  end
end
