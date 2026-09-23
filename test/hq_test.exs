defmodule HqTest do
  use ExUnit.Case, async: true

  test "reports its version" do
    assert Hq.version() =~ ~r/^\d+\.\d+\.\d+$/
  end
end
