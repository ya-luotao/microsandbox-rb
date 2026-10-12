# frozen_string_literal: true

require "tmpdir"

# GHSA-mcw9-9rf6-p4rm, end to end: a sandbox created with a relative bind
# source must mount the SAME host directory when it is started again from a
# different working directory. spec/unit/host_paths_spec.rb covers what is
# persisted; this boots the microVM and looks from the guest.
RSpec.describe "relative host paths across a restart", :integration do
  it "mounts the creating directory's data after a start from another directory" do
    name = unique_sandbox_name("rb-paths")
    Dir.mktmpdir("msb-rb-a-") do |created_in|
      Dir.mktmpdir("msb-rb-b-") do |started_in|
        [[created_in, "from the creating directory"], [started_in, "from the starting directory"]].each do |dir, text|
          FileUtils.mkdir_p(File.join(dir, "data"))
          File.write(File.join(dir, "data", "marker.txt"), text)
        end

        begin
          Dir.chdir(created_in) do
            sandbox = Microsandbox::Sandbox.create(name, image: default_test_image, volumes: {"/data" => "./data"})
            expect(sandbox.fs.read_text("/data/marker.txt")).to eq("from the creating directory")
            sandbox.stop
          end
          Dir.chdir(started_in) do
            sandbox = Microsandbox::Sandbox.start(name)
            expect(sandbox.fs.read_text("/data/marker.txt")).to eq("from the creating directory")
            sandbox.stop
          end
        ensure
          begin
            Microsandbox::Sandbox.remove(name)
          rescue Microsandbox::Error
            nil
          end
        end
      end
    end
  end
end
