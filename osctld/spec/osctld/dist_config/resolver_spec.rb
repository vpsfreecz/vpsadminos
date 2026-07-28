# frozen_string_literal: true

require 'osctld/dist_config'
require 'osctld/dist_config/resolver'

RSpec.describe OsCtld::DistConfig::Resolver do
  describe '.render' do
    it 'renders ordered IPv4 and IPv6 resolvers' do
      expect(described_class.render(['192.0.2.53', '2001:db8::53'])).to eq(
        "nameserver 192.0.2.53\n" \
        "nameserver 2001:db8::53\n" \
        "options edns0\n"
      )
    end

    it 'rejects empty and non-array resolver sets' do
      expect { described_class.render([]) }
        .to raise_error(described_class::Invalid, /at least one/)
      expect { described_class.render('192.0.2.53') }
        .to raise_error(described_class::Invalid, /at least one/)
    end

    it 'rejects directives, whitespace, controls, prefixes, zones, and hostnames' do
      invalid = [
        "192.0.2.53\noptions rotate",
        '192.0.2.53 extra',
        "192.0.2.53\t",
        '192.0.2.53/24',
        'fe80::1%eth0',
        'resolver.example'
      ]

      invalid.each do |resolver|
        expect { described_class.render([resolver]) }
          .to raise_error(described_class::Invalid, /invalid DNS resolver/)
      end
    end

    it 'rejects payloads larger than the runtime handoff bound' do
      resolvers = Array.new(300, '2001:db8:ffff:ffff:ffff:ffff:ffff:ffff')

      expect { described_class.render(resolvers) }
        .to raise_error(described_class::Invalid, /exceeds 4096 bytes/)
    end
  end
end
