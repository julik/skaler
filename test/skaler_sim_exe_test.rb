require "test_helper"
require "open3"
require "tmpdir"

class SkalerSimExeTest < Skaler::TestCase
  EXE = File.expand_path("../exe/skaler_sim", __dir__)

  test "runs a short simulation and writes the SVG and CSV" do
    Dir.mktmpdir do |dir|
      svg = File.join(dir, "trace.svg")
      csv = File.join(dir, "trace.csv")
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "--max-time", "5m", "--no-open", "--output", svg, "--csv", csv)

      assert status.success?, err
      assert_match(/Peak instances:/, err)
      assert File.read(svg).start_with?("<svg")
      assert_equal 7, File.readlines(csv).size # header plus a tick per minute, t=0..5m inclusive
    end
  end
end
