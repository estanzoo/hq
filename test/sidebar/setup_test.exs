defmodule Hq.Sidebar.SetupTest do
  # Runs sidebar/setup.sh against a temporary Claude config folder and Herdr
  # config file, with a fake `herdr` on PATH. The fake's `config check`
  # rejects a file that contains BADTOML, and it records every other call.
  use ExUnit.Case, async: true

  @repo Path.expand("../..", __DIR__)
  @script Path.join(@repo, "sidebar/setup.sh")
  @activity Path.join(@repo, "sidebar/activity.sh")
  @statusline Path.join(@repo, "sidebar/statusline.sh")
  @events ~w(UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure PostToolBatch Stop StopFailure SessionEnd)

  setup do
    root = Path.join(System.tmp_dir!(), "hq-setup-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "herdr"), """
    #!/bin/bash
    if [ "$1 $2" = "config check" ]; then
      if grep -q BADTOML "$HERDR_CONFIG_PATH"; then echo "config: issues found"; exit 1; fi
      echo "config: ok"; exit 0
    fi
    echo "$*" >> #{root}/calls
    """)

    File.chmod!(Path.join(bin, "herdr"), 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      claude: Path.join(root, "claude"),
      settings: Path.join([root, "claude", "settings.json"]),
      herdr: Path.join([root, "herdr", "config.toml"]),
      env: %{
        "PATH" => bin <> ":" <> System.get_env("PATH"),
        "CLAUDE_CONFIG_DIR" => Path.join(root, "claude"),
        "HERDR_CONFIG_PATH" => Path.join([root, "herdr", "config.toml"])
      }
    }
  end

  defp setup_sh(env), do: System.cmd(@script, [], env: env, stderr_to_stdout: true)

  defp settings(ctx), do: ctx.settings |> File.read!() |> JSON.decode!()

  defp write_settings(ctx, map) do
    File.mkdir_p!(ctx.claude)
    File.write!(ctx.settings, JSON.encode!(map))
  end

  # Every hook command of one event, from all of its entries.
  defp commands(s, event),
    do: for(entry <- s["hooks"][event] || [], h <- entry["hooks"], do: h["command"])

  defp backups(path), do: Path.wildcard(path <> ".bak-hq-*")

  defp calls(root) do
    case File.read(Path.join(root, "calls")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  test "on a machine with no config it sets up the statusline, the hooks and the rows", ctx do
    assert {_, 0} = setup_sh(ctx.env)

    s = settings(ctx)
    assert s["statusLine"] == %{"type" => "command", "command" => @statusline}
    for e <- @events, do: assert(commands(s, e) == [@activity], e)
    assert [%{"matcher" => "Bash"}] = s["hooks"]["PreToolUse"]
    assert [%{"hooks" => [%{"async" => true}]}] = s["hooks"]["PostToolBatch"]

    toml = File.read!(ctx.herdr)
    assert toml =~ "[ui.sidebar.agents]"
    assert toml =~ ~s({ token = "$ctx", dim = true }, { token = "$activity" })
    assert "server reload-config" in calls(ctx.root)

    # A file that did not exist has nothing to back up.
    assert backups(ctx.settings) == []
    assert backups(ctx.herdr) == []
  end

  test "a second run changes nothing", ctx do
    setup_sh(ctx.env)
    first = {File.read!(ctx.settings), File.read!(ctx.herdr)}

    assert {out, 0} = setup_sh(ctx.env)
    assert {File.read!(ctx.settings), File.read!(ctx.herdr)} == first
    assert out =~ "already set up"
    assert backups(ctx.settings) == [] and backups(ctx.herdr) == []
  end

  test "other settings and hooks are kept, and the old file is backed up", ctx do
    mine = %{"type" => "command", "command" => "echo mine"}

    write_settings(ctx, %{
      "model" => "opus",
      "permissions" => %{"allow" => ["Bash(hq:*)"]},
      "hooks" => %{
        "PreToolUse" => [%{"matcher" => "Bash", "hooks" => [mine]}],
        "Notification" => [%{"hooks" => [mine]}]
      }
    })

    assert {_, 0} = setup_sh(ctx.env)
    s = settings(ctx)
    assert s["model"] == "opus"
    assert s["permissions"] == %{"allow" => ["Bash(hq:*)"]}
    assert commands(s, "PreToolUse") == ["echo mine", @activity]
    assert commands(s, "Notification") == ["echo mine"]
    assert [backup] = backups(ctx.settings)
    assert backup |> File.read!() |> JSON.decode!() |> Map.get("model") == "opus"
  end

  test "a hook from another checkout of hq is replaced, not doubled", ctx do
    old = "/old/place/hq/sidebar/activity.sh"

    write_settings(ctx, %{
      "statusLine" => %{"type" => "command", "command" => "/old/place/hq/sidebar/statusline.sh"},
      "hooks" => %{
        "Stop" => [%{"hooks" => [%{"type" => "command", "command" => old, "timeout" => 5}]}]
      }
    })

    assert {_, 0} = setup_sh(ctx.env)
    s = settings(ctx)
    assert commands(s, "Stop") == [@activity]
    assert s["statusLine"]["command"] == @statusline
  end

  test "a statusline of your own is kept, with a note", ctx do
    write_settings(ctx, %{"statusLine" => %{"type" => "command", "command" => "~/my-line.sh"}})

    assert {out, 0} = setup_sh(ctx.env)
    assert settings(ctx)["statusLine"]["command"] == "~/my-line.sh"
    assert out =~ "keeps your own statusLine"
    assert commands(settings(ctx), "Stop") == [@activity]
  end

  test "settings that are not valid JSON are left alone", ctx do
    File.mkdir_p!(ctx.claude)
    File.write!(ctx.settings, "{ not json")

    assert {out, 0} = setup_sh(ctx.env)
    assert File.read!(ctx.settings) == "{ not json"
    assert out =~ "not valid JSON"
    # The Herdr part still runs.
    assert File.read!(ctx.herdr) =~ "[ui.sidebar.agents]"
  end

  test "Herdr rows of your own are kept, with a note", ctx do
    own = "[ui.sidebar.agents]\nrows = [[\"state_icon\", \"workspace\"]]\n"
    File.mkdir_p!(Path.dirname(ctx.herdr))
    File.write!(ctx.herdr, own)

    assert {out, 0} = setup_sh(ctx.env)
    assert File.read!(ctx.herdr) == own
    assert out =~ "keeps your own [ui.sidebar.agents] rows"
    assert backups(ctx.herdr) == []
  end

  test "other Herdr settings are kept when the rows are added", ctx do
    File.mkdir_p!(Path.dirname(ctx.herdr))
    File.write!(ctx.herdr, "onboarding = false\n")

    assert {_, 0} = setup_sh(ctx.env)
    toml = File.read!(ctx.herdr)
    assert String.starts_with?(toml, "onboarding = false\n")
    assert toml =~ "[ui.sidebar.agents]"
    assert [backup] = backups(ctx.herdr)
    assert File.read!(backup) == "onboarding = false\n"
  end

  test "config files that are symlinks stay symlinks", ctx do
    # Dotfiles repos often link these files; the change goes to the real file.
    real = Path.join(ctx.root, "dotfiles")
    File.mkdir_p!(real)
    File.write!(Path.join(real, "settings.json"), ~s({"model": "opus"}))
    File.write!(Path.join(real, "config.toml"), "onboarding = false\n")
    File.mkdir_p!(ctx.claude)
    File.mkdir_p!(Path.dirname(ctx.herdr))
    File.ln_s!(Path.join(real, "settings.json"), ctx.settings)
    File.ln_s!(Path.join(real, "config.toml"), ctx.herdr)

    assert {_, 0} = setup_sh(ctx.env)
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(ctx.settings)
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(ctx.herdr)

    real_settings = real |> Path.join("settings.json") |> File.read!() |> JSON.decode!()
    assert real_settings["model"] == "opus"
    assert real_settings["statusLine"]["command"] == @statusline
    assert File.read!(Path.join(real, "config.toml")) =~ "[ui.sidebar.agents]"
  end

  test "a Herdr config that Herdr rejects with the rows is put back", ctx do
    File.mkdir_p!(Path.dirname(ctx.herdr))
    File.write!(ctx.herdr, "# BADTOML\n")

    assert {out, 0} = setup_sh(ctx.env)
    assert File.read!(ctx.herdr) == "# BADTOML\n"
    assert out =~ "was put back"
    assert backups(ctx.herdr) == []
    refute "server reload-config" in calls(ctx.root)
  end
end
