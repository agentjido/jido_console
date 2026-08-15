defmodule Jido.Console.LiveTuiPtyTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Terminal.PlainText

  @moduletag :live
  @project_root Path.expand("../..", __DIR__)

  if System.get_env("JIDO_LIVE_PTY") != "1" do
    @moduletag skip: "set JIDO_LIVE_PTY=1 to test live coding tool selection"
  end

  test "uses path search to list files through the compiled TUI" do
    expect = System.find_executable("expect") || flunk("expect is required for the live PTY test")
    executable = build_executable!()
    capture = capture_path()

    File.write!(capture, "")
    File.chmod!(capture, 0o600)
    on_exit(fn -> File.rm(capture) end)

    {output, status} =
      System.cmd(expect, ["-c", expect_script()],
        cd: @project_root,
        env: [
          {"JIDO_BIN", executable},
          {"JIDO_LIVE_PTY_CAPTURE", capture},
          {"LANG", "en_US.UTF-8"},
          {"LC_ALL", "en_US.UTF-8"},
          {"TERM", "xterm-256color"}
        ],
        stderr_to_stdout: true
      )

    transcript = sanitized_transcript(capture, output)

    assert status == 0,
           "live PTY request failed (expect status #{status}).\n\n" <>
             "Sanitized Expect and terminal transcript:\n#{transcript}"

    assert transcript =~ "live_pty=passed"
    assert transcript =~ "coding.search"
    assert transcript =~ "mix.exs"
    refute transcript =~ "coding.git_status"
    refute transcript =~ "Jidoka execution failed"
  end

  defp build_executable! do
    executable = Path.join(@project_root, "jido")

    if executable_current?(executable) do
      executable
    else
      {output, status} =
        System.cmd("mix", ["escript.build"],
          cd: @project_root,
          env: [{"MIX_ENV", "prod"}, {"JIDO_CONSOLE_JIDOKA_PATH", nil}],
          stderr_to_stdout: true
        )

      assert status == 0, "could not build the live PTY executable:\n#{output}"
      executable
    end
  end

  defp executable_current?(executable) do
    System.get_env("JIDO_LIVE_PTY_REBUILD") != "1" and File.regular?(executable) and
      source_paths()
      |> Enum.map(&File.stat!(&1, time: :posix).mtime)
      |> Enum.max(fn -> 0 end)
      |> then(&(&1 <= File.stat!(executable, time: :posix).mtime))
  end

  defp source_paths do
    ["mix.exs", "mix.lock", "config/**/*.exs", "lib/**/*.{ex,exs}", "priv/**/*"]
    |> Enum.flat_map(&Path.wildcard(Path.join(@project_root, &1)))
    |> Enum.filter(&File.regular?/1)
  end

  defp capture_path do
    Path.join(
      System.tmp_dir!(),
      "jido-live-pty-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}.log"
    )
  end

  defp sanitized_transcript(path, expect_output) do
    capture = if File.exists?(path), do: File.read!(path), else: ""

    (capture <> "\n" <> expect_output)
    |> PlainText.clean()
    |> redact_secrets()
    |> retain_tail(20_000)
  end

  defp redact_secrets(text) do
    text
    |> String.replace(~r/sk-[a-zA-Z0-9_-]{8,}/, "[REDACTED]")
    |> String.replace(~r/(authorization\s*:\s*bearer\s+)[^\s]+/i, "\\1[REDACTED]")
    |> String.replace(~r/(api[_-]?key\s*[=:]\s*)[^\s]+/i, "\\1[REDACTED]")
  end

  defp retain_tail(text, limit) do
    if String.length(text) <= limit, do: text, else: String.slice(text, -limit, limit)
  end

  defp expect_script do
    ~S'''
    encoding system utf-8
    set timeout 90
    set stty_init "rows 24 columns 100"
    log_user 1
    log_file -noappend $env(JIDO_LIVE_PTY_CAPTURE)

    proc fail_live {message code} {
      global spawn_id
      puts $message
      catch {send "\033"}
      expect {
        eof {}
        timeout {
          catch {close}
          catch {wait}
        }
      }
      exit $code
    }

    spawn -noecho $env(JIDO_BIN)

    expect {
      -re {idle .* Enter sends} {}
      -re {startup failed .*} {fail_live "live_pty=startup_error" 2}
      timeout {fail_live "live_pty=initial_timeout" 3}
      eof {puts "live_pty=early_exit"; exit 4}
    }

    stty -isig < $spawn_out(slave,name)
    send "What files are in this folder?\r"

    expect {
      -re {coding\.git_status} {fail_live "live_pty=wrong_tool" 5}
      -re {coding\.search} {}
      -re {Jidoka execution failed} {fail_live "live_pty=generic_error" 5}
      -re {error .*} {fail_live "live_pty=request_error" 6}
      timeout {fail_live "live_pty=response_timeout" 7}
      eof {puts "live_pty=response_exit"; exit 8}
    }

    expect {
      -re {coding\.git_status} {fail_live "live_pty=wrong_tool" 9}
      -re {Jidoka execution failed} {fail_live "live_pty=generic_error" 9}
      -re {error .*} {fail_live "live_pty=request_error" 10}
      -re {mix\.exs} {}
      timeout {fail_live "live_pty=completion_timeout" 11}
      eof {puts "live_pty=completion_exit"; exit 12}
    }

    expect {
      -re {coding\.git_status} {fail_live "live_pty=wrong_tool" 13}
      -re {Jidoka execution failed} {fail_live "live_pty=generic_error" 14}
      -re {error .*} {fail_live "live_pty=request_error" 15}
      -re {idle .* Enter sends} {}
      timeout {fail_live "live_pty=completion_timeout" 16}
      eof {puts "live_pty=completion_exit"; exit 17}
    }

    send "\033"
    expect {
      eof {}
      timeout {fail_live "live_pty=shutdown_timeout" 18}
    }

    set wait_result [wait]
    if {[llength $wait_result] != 4 || [lindex $wait_result 2] != 0 || [lindex $wait_result 3] != 0} {
      puts "live_pty=bad_exit:$wait_result"
      exit 19
    }

    puts "live_pty=passed"
    '''
  end
end
