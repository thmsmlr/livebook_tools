defmodule LivebookToolsTest do
  use ExUnit.Case
  doctest LivebookTools

  test "greets the world" do
    assert LivebookTools.hello() == :world
  end
end
