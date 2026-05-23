import ../../make-test.nix (
  { pkgs }:
  {
    name = "driver-rspec";

    description = ''
      Test RSpec example groups and expectations
    '';

    tags = [ "ci" ];

    testScriptJobs = 5;

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScripts = {
      base = {
        description = ''
          Test RSpec example groups and expectations
        '';
        script = ''
          execution_order = []

          before(:suite) do
            execution_order << :before_suite

            machine.stop if machine.running?
          end

          after(:suite) do
            execution_order << :after_suite

            machine.stop if machine.running?

            expect(execution_order).to eq(%i[
              before_suite
              before_context
              before_example
              it
              after_example
              before_example
              it
              after_example
              before_context_nested
              before_example_nested
              it_nested
              after_example_nested
              before_example_nested
              it_nested
              after_example_nested
              after_context_nested
              after_context
              after_suite
            ])
          end

          expect { before(:context) {} }.to raise_error(RuntimeError)
          expect { before(:example) {} }.to raise_error(RuntimeError)
          expect { after(:context) {} }.to raise_error(RuntimeError)
          expect { after(:example) {} }.to raise_error(RuntimeError)

          describe 'machine' do
            before(:context) do
              execution_order << :before_context
            end

            after(:context) do
              execution_order << :after_context
            end

            before(:example) do
              execution_order << :before_example
            end

            after(:example) do
              execution_order << :after_example
            end

            it 'is really not running' do
              execution_order << :it

              expect(machine.running?).to be(false)
            end

            it 'is truly not running' do
              execution_order << :it

              expect(machine.running?).to be(false)
            end

            context 'when running' do
              before(:context) do
                execution_order << :before_context_nested

                machine.start unless machine.running?
              end

              after(:context) do
                execution_order << :after_context_nested
              end

              before(:example) do
                execution_order << :before_example_nested
              end

              after(:example) do
                execution_order << :after_example_nested
              end

              it 'is really running' do
                execution_order << :it_nested

                expect(machine.running?).to be(true)
              end

              it 'is truly running' do
                execution_order << :it_nested

                expect(machine.running?).to be(true)
              end
            end
          end

          describe 'pending' do
            it 'can be marked as pending without reason' do
              pending
              expect(0).to eq(1)
            end

            it 'can be marked as pending with reason' do
              pending('this needs fixing')
              expect(0).to eq(1)
            end

            pending 'can be declared like this' do
              expect(0).to eq(1)
            end

            pending 'without a block is skipped'

            it 'can also be set by option', pending: true do
              expect(0).to eq(1)
            end

            begin
              pending 'pending with pending option cannot be called', pending: false
            rescue ArgumentError
              # pass
            else
              raise 'pending was called with pending option'
            end
          end

          describe 'skip' do
            it 'it without a block is skipped'

            skip 'skip without a block is skipped'

            skip 'declare as skipped' do
              aise Exception, "this shouldn't be executed"
            end

            it 'can be skipped from example block without reason' do
              skip
              raise Exception, "this shouldn't be executed"
            end

            it 'can be skipped from example block with reason' do
              skip("it's not ready")
              raise Exception, "this shouldn't be executed"
            end

            it 'can be skipped using option', skip: true do
              raise Exception, "this shouldn't be executed"
            end

            begin
              skip 'skip with skip option cannot be called', skip: false
            rescue ArgumentError
              # pass
            else
              raise 'skip was called with skip option'
            end

            begin
              skip 'skip with pending option cannot be called', pending: false
            rescue ArgumentError
              # pass
            else
              raise 'skip was called with pending option'
            end
          end

          example_range = (1..5).to_a
          group_range = (6..10).to_a
          order_rand = []
          order_defined = []
          order_nested = []
          seed = 1

          describe 'order' do
            context 'by rand (default)' do
              before(:context) do
                order_rand.clear
              end

              example_range.each do |i|
                example "example ##{i}" do
                  order_rand << i
                end
              end

              group_range.each do |i|
                context "context ##{i}" do
                  example "example ##{i}" do
                    order_rand << i
                  end
                end
              end

              after(:context) do
                expect(order_rand.sort).to eq(example_range + group_range)
              end
            end

            context 'by rand with seed', order: seed do
              before(:context) do
                order_rand.clear
              end

              example_range.each do |i|
                example "example ##{i}" do
                  order_rand << i
                end
              end

              group_range.each do |i|
                context "context ##{i}" do
                  example "example ##{i}" do
                    order_rand << i
                  end
                end
              end

              after(:context) do
                expect(order_rand).to eq(example_range.shuffle(random: Random.new(seed)) + group_range.shuffle(random: Random.new(seed)))
              end
            end

            context 'by defined', order: :defined do
              example_range.each do |i|
                example "##{i}" do
                  order_defined << i
                end
              end

              group_range.each do |i|
                context "context ##{i}" do
                  example "example ##{i}" do
                    order_defined << i
                  end
                end
              end

              after(:context) do
                expect(order_defined).to eq(example_range + group_range)
              end
            end

            context 'is per group', order: seed do
              example_range.each do |i|
                example "##{i}" do
                  order_nested << i
                end
              end

              context 'nested', order: :defined do
                example_range.each do |i|
                  example "##{i}" do
                    order_nested << i
                  end
                end
              end

              after(:context) do
                expect(order_nested).to eq(example_range.shuffle(random: Random.new(seed)) + example_range)
              end
            end
          end
        '';
      };

      config = {
        description = ''
          Test RSpec with modified default configuration
        '';
        script = ''
          seed = 2
          range = (1..5).to_a
          order = []

          configure_examples do |config|
            config.default_order = seed
          end

          describe 'order by preconfigured random seed' do
            range.each do |i|
              example "example ##{i}" do
                order << i
              end
            end

            after(:context) do
              expect(order).to eq(range.shuffle(random: Random.new(seed)))
            end
          end
        '';
      };

      script-attempts = {
        description = ''
          Test that individual test scripts can be retried
        '';
        attempts = 2;
        script = ''
          state_dir = File.dirname(machine.send(:console_log_path))
          marker = File.join(state_dir, 'script-attempts.marker')

          if File.exist?(marker)
            File.delete(marker)
          else
            File.write(marker, "retry\n")
            fail 'intentional first failure'
          end
        '';
      };
    };
  }
)
