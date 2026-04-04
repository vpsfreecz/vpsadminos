# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::View do
  it 'requires subclasses to implement start' do
    expect { described_class.new(double('model'), 1).start }.to raise_error(NotImplementedError)
  end
end
