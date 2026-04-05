# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Config::ParseAttrs do
  it 'parses key/value lines and ignores invalid or empty values' do
    op_class = Class.new(described_class) do
      class << self
        attr_accessor :result, :seen
      end

      def syscmd(cmd)
        self.class.seen = cmd
        self.class.result
      end
    end
    op_class.result = command_result("DISTNAME=Alpine\nBROKEN\nEMPTY=\nRELVER=3.20\n")

    expect(op_class.new('/scripts', :image, 'alpine').execute).to eq(
      'DISTNAME' => 'Alpine',
      'RELVER' => '3.20'
    )
    expect(op_class.seen).to eq('/scripts/bin/config image show alpine')
  end
end
