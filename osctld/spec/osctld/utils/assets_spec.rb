# frozen_string_literal: true

require 'osctld/utils/assets'

RSpec.describe OsCtld::Utils::Assets do
  it 'returns validated assets in exported form' do
    host = Class.new do
      include OsCtld::Utils::Assets
    end.new
    asset = Struct.new(:type, :path, :opts, :state, :errors, keyword_init: true).new(
      type: :file,
      path: '/run/osctl.sock',
      opts: { mode: 0o600 },
      state: :ok,
      errors: []
    )
    validator_class = stub_const('OsCtld::Assets::Validator', Class.new do
      def initialize(*); end

      def validate; end
    end)
    validator = instance_double(validator_class, validate: [asset])
    allow(validator_class).to receive(:new).with(:assets).and_return(validator)

    expect(host.list_and_validate_assets(Struct.new(:assets).new(:assets))).to eq(
      [
        {
          type: :file,
          path: '/run/osctl.sock',
          opts: { mode: 0o600 },
          state: :ok,
          errors: []
        }
      ]
    )
  end
end
