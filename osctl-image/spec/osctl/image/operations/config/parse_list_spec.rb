# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Config::ParseList do
  it 'splits the command output into list entries' do
    op_class = Class.new(described_class) do
      class << self
        attr_accessor :result, :seen
      end

      def syscmd(cmd)
        self.class.seen = cmd
        self.class.result
      end
    end
    op_class.result = command_result("alpine\ndebian\n")

    expect(op_class.new('/scripts', :image).execute).to eq(%w[alpine debian])
    expect(op_class.seen).to eq('/scripts/bin/config image list')
  end
end
