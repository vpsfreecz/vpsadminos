# frozen_string_literal: true

module BuildScriptsHelpers
  def create_build_scripts_dir(path)
    bin = File.join(path, 'bin')
    FileUtils.mkdir_p(bin)

    %w[config runner test].each do |name|
      file = File.join(bin, name)
      File.write(file, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, file)
    end
  end

  def create_fake_vpsadminos_checkout(root, scripts_dir:)
    FileUtils.mkdir_p(File.join(root, 'os', 'lib', 'nixos-container'))

    target = File.join(root, 'image-scripts')
    File.symlink(scripts_dir, target)
  end
end

RSpec.configure do |config|
  config.include BuildScriptsHelpers
end
