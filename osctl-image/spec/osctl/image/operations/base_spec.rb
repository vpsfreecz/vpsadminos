# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Base do
  it 'instantiates and executes subclasses via .run' do
    subclass = Class.new(described_class) do
      def execute
        :ok
      end
    end

    expect(subclass.run).to eq(:ok)
  end
end
