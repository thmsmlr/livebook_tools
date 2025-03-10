defmodule LivebookTools.CLI do
  require Logger

  @moduledoc """
  Command-line interface for LivebookTools.
  """

  @doc """
  Entry point for the command-line application.
  """
  def main(args) do
    {opts, cmd_args, _} =
      OptionParser.parse_head(
        args,
        strict: [help: :boolean],
        aliases: [h: :help]
      )

    case {opts, cmd_args} do
      {%{help: true}, _} ->
        print_help()

      {_, ["mcp_server"]} ->
        mcp_server()

      {_, ["get_livemd_outputs" | rest]} ->
        case rest do
          [file_path] ->
            get_livemd_outputs(file_path)

          [] ->
            IO.puts("Error: Missing file path for get_livemd_outputs command\n")
            print_help()

          _ ->
            IO.puts("Error: Too many arguments for get_livemd_outputs command\n")
            print_help()
        end

      {_, ["watch" | rest]} ->
        case rest do
          [file_path] ->
            watch(file_path)

          [] ->
            IO.puts("Error: Missing file path for watch command\n")
            print_help()

          _ ->
            IO.puts("Error: Too many arguments for watch command\n")
            print_help()
        end

      {_, ["run" | rest]} ->
        IO.inspect(rest, label: "RUN REST")

        case rest do
          [file_path | argv] ->
            run(file_path, argv)

          [] ->
            IO.puts("Error: Missing file path for run command\n")
            print_help()

          _ ->
            IO.puts("Error: Too many arguments for run command\n")
            print_help()
        end

      {_, ["convert" | rest]} ->
        case rest do
          [input_path, output_path] ->
            convert(input_path, output_path)

          [_] ->
            IO.puts("Error: Missing output path for convert command\n")
            print_help()

          [] ->
            IO.puts("Error: Missing file paths for convert command\n")
            print_help()

          _ ->
            IO.puts("Error: Too many arguments for convert command\n")
            print_help()
        end

      {_, []} ->
        IO.puts("Error: No command specified\n")
        print_help()

      {_, [cmd | _]} ->
        IO.puts("Error: Unknown command '#{cmd}'\n")
        print_help()
    end
  end

  @doc """
  Converts a Livebook file to an Elixir script and runs it.
  """
  def run(file_path, argv) do
    with {:ok, content} <- File.read(file_path),
         {notebook, _} <- Livebook.LiveMarkdown.notebook_from_livemd(content) do
      exs_file = """
      Process.put(:livebook_success, false)
      #{Livebook.Notebook.Export.Elixir.notebook_to_elixir(notebook)}
      Process.put(:livebook_success, true)
      """

      after_exs_file = """
      System.halt(if Process.get(:livebook_success), do: 0, else: 1)
      """

      dir = Path.dirname(file_path)
      basename = Path.basename(file_path, Path.extname(file_path))
      random_string = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
      tmp_file_path = Path.join(dir, ".#{basename}-#{random_string}.exs")
      tmp_after_file_path = Path.join(dir, ".#{basename}-#{random_string}.after.exs")

      File.write!(tmp_file_path, exs_file)
      File.write!(tmp_after_file_path, after_exs_file)

      escaped_argv = Enum.map_join(argv, " ", fn arg -> String.replace(arg, "'", "\\'") end)

      port =
        Port.open(
          {:spawn, "bash -c 'cat #{tmp_after_file_path} | iex --dot-iex #{tmp_file_path} -- #{escaped_argv}'"},
          [
            :nouse_stdio,
            :exit_status
          ]
        )

      receive do
        {^port, {:exit_status, exit_code}} ->
          File.rm(tmp_file_path)
          File.rm(tmp_after_file_path)
          System.halt(exit_code)
      end
    end
  end

  ############################################################
  ##                        COMMANDS                        ##
  ############################################################

  @doc """
  Watches a Livebook file for changes and syncs it with an open Livebook session.
  """
  def watch(file_path) do
    ensure_node_started()
    file_path = Path.expand(file_path)

    # Make sure that we can connect to the Livebook session for this file, will exit if not
    with_livebook_session(file_path, fn _livebook_pid ->
      IO.puts("Connected to Livebook session for #{file_path} ")
    end)

    IO.puts("Watching #{file_path} for changes...")

    LivebookTools.Watcher.start_link(file_path, fn file_path ->
      Logger.info("File #{file_path} changed, syncing...")

      with_livebook_session(file_path, fn livebook_pid ->
        LivebookTools.Sync.sync(livebook_pid, file_path)
        Livebook.Session.queue_full_evaluation(livebook_pid, [])
      end)
    end)

    :timer.sleep(:infinity)
  end

  @doc """
  Converts a Livebook file to an Elixir script and writes it to the specified location.
  """
  def convert(input_path, output_path) do
    with {:ok, content} <- File.read(input_path),
         {notebook, _} <- Livebook.LiveMarkdown.notebook_from_livemd(content) do
      exs_content = Livebook.Notebook.Export.Elixir.notebook_to_elixir(notebook)

      case File.write(output_path, exs_content) do
        :ok ->
          IO.puts("Successfully converted #{input_path} to #{output_path}")

        {:error, reason} ->
          IO.puts("Error writing to #{output_path}: #{:file.format_error(reason)}")
          System.halt(1)
      end
    else
      {:error, :enoent} ->
        IO.puts("Error: File #{input_path} not found")
        System.halt(1)

      {:error, reason} ->
        IO.puts("Error reading #{input_path}: #{:file.format_error(reason)}")
        System.halt(1)

      _ ->
        IO.puts("Error: Failed to parse Livebook file #{input_path}")
        System.halt(1)
    end
  end

  @doc """
  Starts the MCP server running over STDIO.
  """
  def mcp_server() do
    ensure_node_started()
    LivebookTools.MCPServer.start()
  end

  @doc """
  Gets the outputs of a Livebook file by connecting to a running Livebook instance.
  """
  def get_livemd_outputs(file_path) do
    ensure_node_started()
    file_path = Path.expand(file_path)

    with_livebook_session(file_path, fn livebook_pid ->
      outputs = LivebookTools.Sync.get_livemd_outputs(livebook_pid)
      IO.puts(outputs)
    end)
  end

  ############################################################
  ##                        HELPERS                         ##
  ############################################################

  defp ensure_node_started do
    rand_str = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    node_name = String.to_atom("livebook_tools_#{rand_str}@127.0.0.1")
    Node.start(node_name)
    Node.set_cookie(Node.self(), :secret)
  end

  defp with_livebook_session(file_path, success_fn) do
    livebook_node = System.get_env("LIVEBOOK_NODE", "livebook@127.0.0.1") |> String.to_atom()

    with {:ok, discovered_node} <- LivebookTools.Sync.discover_livebook_node(),
         true <- discovered_node == livebook_node || {:error, :wrong_node, discovered_node},
         true <- Node.connect(livebook_node),
         {:ok, livebook_pid} <-
           LivebookTools.Sync.find_livebook_session_pid_for_file(livebook_node, file_path) do
      success_fn.(livebook_pid)
    else
      {:error, :no_livebook_node} ->
        IO.puts("""
        Error: No livebook node found.

        Please make sure Livebook is running and the node name and cookie match your configuration.
        You can configure these values using environment variables:

        LIVEBOOK_NODE=livebook@127.0.0.1
        LIVEBOOK_COOKIE=secret

        For more information, see the project README:
        https://github.com/thmsmlr/livebook_tools#running-livebook
        """)

        System.halt(1)

      {:error, :wrong_node, discovered_node} ->
        IO.puts("""
        Error: Found a Livebook node, but it doesn't match your LIVEBOOK_NODE setting.

        Found: #{discovered_node}
        Expected: #{livebook_node}

        Please update your LIVEBOOK_NODE environment variable to match the running instance.
        """)

        System.halt(1)

      {:error, :no_livebook_session} ->
        IO.puts("""
        Error: No livebook session found for #{file_path}

        Make sure you open #{file_path} in Livebook before running this command.
        """)

        System.halt(1)

      false ->
        IO.puts("""
        Error: Could not connect to Livebook node #{livebook_node}.

        Please make sure Livebook is running and the node name and cookie match your configuration.
        You can configure these values using environment variables:

        LIVEBOOK_NODE=livebook@127.0.0.1
        LIVEBOOK_COOKIE=secret

        For more information, see the project README:
        https://github.com/thmsmlr/livebook_tools#running-livebook
        """)

        System.halt(1)
    end
  end

  defp print_help do
    IO.puts("""
    LivebookTools - Utilities for working with Livebook files

    Usage:
      livebook_tools [command] [options]

    Commands:
      watch <file>              Watch a Livebook file for changes and sync with open Livebook session
      run <file> [args]         Convert a Livebook file to an Elixir script and run it
      convert <input> <output>  Convert a Livebook file to an Elixir script and save it to the specified location
      mcp_server                Start the MCP server running over STDIO
      get_livemd_outputs <file>  Get the outputs of a Livebook file

    Options:
      -h, --help                Show this help message
    """)
  end
end
