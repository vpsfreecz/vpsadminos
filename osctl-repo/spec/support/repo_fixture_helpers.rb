# frozen_string_literal: true

module RepoFixtureHelpers
  def write_fixture_file(dir, name, contents)
    path = File.join(dir, name)
    File.binwrite(path, contents)
    path
  end

  def image_record(vendor:, variant:, arch:, distribution:, version:, tags: [],
                   formats: %w[tar])
    dir = File.join(vendor, variant, arch, distribution, version)

    {
      vendor: vendor,
      variant: variant,
      arch: arch,
      distribution: distribution,
      version: version,
      tags: tags,
      image: formats.to_h do |fmt|
        file = fmt.to_s == 'tar' ? 'image-archive.tar' : 'image-stream.tar'
        [fmt.to_s, File.join(dir, file)]
      end
    }
  end

  def index_json(vendors: { default: nil }, images: [])
    JSON.dump(vendors: vendors, images: images)
  end
end

RSpec.configure do |config|
  config.include RepoFixtureHelpers
end
