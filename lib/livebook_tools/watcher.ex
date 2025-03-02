defmodule LivebookTools.Watcher do
  use GenServer
  require Logger

  # Check every 100ms
  @check_interval 100

  def start_link(file_path, callback) do
    GenServer.start_link(__MODULE__, {file_path, callback})
  end

  def init({file_path, callback}) do
    # Get initial file info
    initial_info = get_file_info(file_path)

    # Schedule the first check
    schedule_check()

    {:ok,
     %{
       file_path: file_path,
       callback: callback,
       last_info: initial_info
     }}
  end

  def handle_info(:check_file, state) do
    %{file_path: file_path, callback: callback, last_info: last_info} = state

    current_info = get_file_info(file_path)

    # If the file has changed, call the callback
    if file_changed?(last_info, current_info) do
      callback.(file_path)
    end

    # Schedule the next check
    schedule_check()

    {:noreply, %{state | last_info: current_info}}
  end

  defp get_file_info(file_path) do
    case File.stat(file_path) do
      {:ok, stat} -> stat
      {:error, _reason} -> nil
    end
  end

  defp file_changed?(nil, _current_info), do: false
  defp file_changed?(_last_info, nil), do: false

  defp file_changed?(last_info, current_info) do
    last_info.mtime != current_info.mtime ||
      last_info.size != current_info.size
  end

  defp schedule_check do
    Process.send_after(self(), :check_file, @check_interval)
  end
end
