# frozen_string_literal: true

# rubocop:disable RSpec/VerifiedDoubles

require 'osctld/hook'
require 'osctld/pool/hooks'

RSpec.describe OsCtld::Pool::Hooks do
  let(:pool) do
    double(name: 'tank', dataset: 'tank', state: :active)
  end

  it 'registers pool hook classes under the expected names' do
    expect(OsCtld::Hook.exist?(OsCtld::Pool, :pre_import)).to be(true)
    expect(OsCtld::Hook.exist?(OsCtld::Pool, :post_export)).to be(true)
  end

  it 'builds pool hook environments' do
    hook = described_class::PreExport.new(pool, {})

    expect(hook.send(:environment)).to include(
      'OSCTL_POOL_NAME' => 'tank',
      'OSCTL_POOL_DATASET' => 'tank',
      'OSCTL_POOL_STATE' => 'active'
    )
  end
end
# rubocop:enable RSpec/VerifiedDoubles
