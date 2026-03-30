# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/utils/exception'

RSpec.describe OsCtl::Lib::Utils::Exception do
  let(:helper_class) do
    Class.new do
      include OsCtl::Lib::Utils::Exception
    end
  end

  it 'removes nix store gem prefixes while leaving other lines unchanged' do
    helper = helper_class.new
    backtrace = [
      '/nix/store/abc/lib/ruby/gems/3.4.0/gems/demo-1.0.0/lib/demo.rb:1',
      '/work/tree/lib/app.rb:2'
    ]

    expect(helper.denixstorify(backtrace)).to eq(
      [
        'demo-1.0.0/lib/demo.rb:1',
        '/work/tree/lib/app.rb:2'
      ]
    )
  end
end
