require 'spec_helper'
require 'open3'

RSpec.describe OsCtl::Image::AssignedConfig do
  it 'freezes repeated config sourcing and retry reuse across a date rollover' do
    Dir.mktmpdir do |dir|
      scripts = File.join(dir, 'scripts')
      FileUtils.cp_r(File.join(REPO_ROOT, 'image-scripts'), scripts)
      image_dir = File.join(scripts, 'images', 'clock-test')
      FileUtils.mkdir_p(image_dir)
      clock = File.join(dir, 'date')
      File.write(clock, '20261105')
      File.write(File.join(image_dir, 'config.sh'), <<~SH)
        BUILDER=fedora
        DISTNAME=clock
        SPIN=rolling
        SPINVER=$(cat #{Shellwords.escape(clock)})
        RELVER=$SPIN-$SPINVER
        VARIANT=minimal
      SH
      File.write(File.join(image_dir, 'build.sh'), <<~SH)
        . "$IMAGEDIR/config.sh"
        printf '%s/%s/%s' "$RELVER" "$SPINVER" "$BUILD_VARIANT" > "$INSTALL/captured"
      SH
      File.write(File.join(scripts, 'tests/capture_fixture.sh'), <<~SH)
        . "$BASEDIR/images/$DIRNAME/config.sh"
        printf '%s/%s/%s' "$RELVER" "$SPINVER" "$BUILD_VARIANT"
      SH
      assigned = described_class.capture(scripts, 'clock-test', source: 'a' * 40)
      path = File.join(dir, 'assignment.json')
      assigned.save(path)
      File.write(clock, '20261106')
      private_paths = ['', 'bin', 'bin/runner', 'bin/test', 'images', 'images/clock-test',
                       'images/clock-test/config.sh', 'images/clock-test/build.sh', 'tests', 'tests/capture_fixture.sh']
      originals = private_paths.to_h do |relative|
        original = File.join(scripts, relative)
        executable = File.directory?(original) || File.executable?(original)
        File.chmod(executable ? 0o700 : 0o600, original)
        [relative, [File.stat(original).mode & 0o777, File.file?(original) ? File.read(original) : nil]]
      end

      2.times do
        described_class.load(path).with_scripts(scripts) do |copy|
          originals.each do |relative, (mode, _content)|
            copied_mode = File.stat(File.join(copy, relative)).mode & 0o777
            required = mode == 0o700 ? 0o055 : 0o044
            expect(copied_mode & required).to eq(required), "#{relative}: #{copied_mode.to_s(8)} needs #{required.to_s(8)}"
            expect(copied_mode & 0o022).to eq(0)
          end
          image = OsCtl::Image::Image.new(copy, 'clock-test')
          image.load_config
          expect(image.version).to eq('rolling-20261105')
          shell, status = Open3.capture2('bash', '-c', '. "$1"; . "$1"; printf "%s/%s" "$RELVER" "$SPINVER"',
                                         'capture-test', File.join(copy, 'images/clock-test/config.sh'))
          expect(status.success?).to be(true)
          expect(shell).to eq('rolling-20261105/20261105')
          work = File.join(dir, 'work')
          install = File.join(dir, 'install')
          FileUtils.mkdir_p([work, install])
          _output, built = Open3.capture2e({ 'VPSADMINOS_IMAGE_MOUNT_NAMESPACE' => '1' },
                                           File.join(copy, 'bin/runner'), 'image', 'build', 'fixture', work, install,
                                           'clock-test#variant=minimal')
          expect(built.success?).to be(true)
          expect(File.read(File.join(install, 'captured'))).to eq('rolling-20261105/20261105/minimal')
          tested, tested_status = Open3.capture2e(File.join(copy, 'bin/test'), 'image', 'run',
                                                  'clock-test#variant=minimal', 'capture_fixture', 'fixture')
          expect(tested_status.success?).to be(true)
          expect(tested).to eq('rolling-20261105/20261105/minimal')
        end
      end
      originals.each do |relative, expected|
        original = File.join(scripts, relative)
        expect([File.stat(original).mode & 0o777, File.file?(original) ? File.read(original) : nil]).to eq(expected)
      end
      expect(File.read(File.join(image_dir, 'config.sh'))).to include('$(cat')
    end
  end

  it 'rejects altered captured identities rather than silently reassigning a retry' do
    data = { 'schema' => 1, 'name' => 'x', 'source' => 'a' * 40, 'config' => {} }
    data['config_digest'] = described_class.digest(data)
    data['source'] = 'b' * 40
    expect { described_class.new(data) }.to raise_error(ArgumentError, /digest mismatch/)
  end
end
