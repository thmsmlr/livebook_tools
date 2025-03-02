defmodule LivebookTools.CLI do
  require Logger

  @moduledoc """
  Command-line interface for LivebookTools.
  """

  @doc """
  Entry point for the command-line application.
  """
  def main(args) do
    rand_str = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    node_name = String.to_atom("livebook_tools_#{rand_str}@127.0.0.1")
    Node.start(node_name)
    Node.set_cookie(Node.self(), :secret)

    {opts, cmd_args, _} =
      OptionParser.parse(
        args,
        strict: [help: :boolean],
        aliases: [h: :help]
      )

    case {opts, cmd_args} do
      {%{help: true}, _} ->
        print_help()

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
        case rest do
          [file_path] ->
            run(file_path)

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
  def run(file_path) do
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

      basename = Path.basename(file_path, Path.extname(file_path))
      random_string = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
      tmp_file_path = System.tmp_dir() <> "/" <> basename <> random_string <> ".exs"
      tmp_after_file_path = System.tmp_dir() <> "/" <> basename <> random_string <> ".after.exs"

      File.write!(tmp_file_path, exs_file)
      File.write!(tmp_after_file_path, after_exs_file)

      port =
        Port.open({:spawn, "bash -c 'cat #{tmp_after_file_path} | iex --dot-iex #{tmp_file_path}'"}, [
          :nouse_stdio,
          :exit_status
        ])

      receive do
        {^port, {:exit_status, exit_code}} ->
          File.rm(tmp_file_path)
          System.halt(exit_code)
      end
    end
  end

  @doc """
  Watches a Livebook file for changes and syncs it with an open Livebook session.
  """
  def watch(file_path) do
    file_path = Path.expand(file_path)
    IO.puts("Watching #{file_path} for changes...")

    LivebookTools.Watcher.start_link(file_path, fn file_path ->
      Logger.info("File #{file_path} changed, syncing...")

      with {:ok, livebook_node} <- LivebookTools.Sync.discover_livebook_node(),
           true <- Node.connect(livebook_node),
           {:ok, livebook_session_pid} <-
             LivebookTools.Sync.find_livebook_session_pid_for_file(livebook_node, file_path) do
        LivebookTools.Sync.sync(livebook_session_pid, file_path)
        Livebook.Session.queue_full_evaluation(livebook_session_pid, [])
      else
        {:error, :no_livebook_node} ->
          Logger.error("""
          No livebook node found.

          Please start Livebook with the following command:

          LIVEBOOK_NODE=livebook@127.0.0.1 livebook server
          """)

        {:error, :no_livebook_session} ->
          Logger.error("""
          No livebook session found for #{file_path}

          Make sure you open #{file_path} in Livebook before running this command.
          """)
      end
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

  defp print_help do
    IO.puts("""
    LivebookTools - Utilities for working with Livebook files

    Usage:
      livebook_tools [command] [options]

    Commands:
      watch <file>              Watch a Livebook file for changes and sync with open Livebook session
      run <file>                Convert a Livebook file to an Elixir script and run it
      convert <input> <output>  Convert a Livebook file to an Elixir script and save it to the specified location

    Options:
      -h, --help                Show this help message
    """)
  end
end
