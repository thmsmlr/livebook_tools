defmodule LivebookTools.MCPServer do
  @moduledoc """
  Starts the MCP server running on STDIN/STDOUT.
  """

  def start() do
    :io.setopts(binary: true)
    handle_request_loop()
  end

  defp handle_request_loop do
    with {:ok, request} <- get_line() do
      try do
        handle_request(request)
      rescue
        _error ->
          reply(%{
            jsonrpc: "2.0",
            id: request["id"],
            error: %{
              code: -32603,
              message: "Internal error"
            }
          })
      end

      handle_request_loop()
    else
      :eof ->
        :ok
    end
  end

  defp handle_request(%{"method" => "tools/list", "id" => request_id}) do
    reply(%{
      jsonrpc: "2.0",
      id: request_id,
      result: %{
        tools: [
          %{
            name: "fetch_livemd_outputs",
            description: """
            Fetches the evaluated cell outputs of a Livebook notebook.

            You can use this tool to get the outputs of a livemd file any time you've changed it and want to see the results of your change.
            """,
            inputSchema: %{
              type: "object",
              required: ["file_path"],
              properties: %{
                file_path: %{
                  type: "string",
                  description:
                    "The absolute path to the livemd file for the Livebook, it must be a full path like /Users/thomas/path/to/file.livemd"
                }
              }
            },
            outputSchema: %{
              type: "object",
              required: ["output"],
              properties: %{
                output: %{
                  type: "string",
                  description: "The livebook with the evaluated cell outputs"
                }
              }
            }
          }
        ]
      }
    })
  end

  defp handle_request(%{"method" => "resources/list", "id" => request_id}) do
    reply(%{
      jsonrpc: "2.0",
      id: request_id,
      result: %{
        resources: []
      }
    })
  end

  defp handle_request(%{"method" => "tools/call", "id" => request_id, "params" => params}) do
    try do
      handle_tool_call(request_id, params)
    rescue
      error ->
        reply(%{
          jsonrpc: "2.0",
          id: request_id,
          error: %{code: -32603, message: inspect(error)}
        })
    end
  end

  defp handle_request(%{"method" => "initialize", "id" => request_id}),
    do:
    reply(%{
      jsonrpc: "2.0",
      id: request_id,
      result: %{
        protocolVersion: "2024-11-05",
        capabilities: %{
          tools: %{ listChanged: true }
        },
        serverInfo: %{
          name: "LivebookTools MCP Server",
          version: "0.0.1"
        }
      }
    })

  defp handle_request(%{"method" => "notifications/initialized"}), do: :ok

  defp handle_request(request) do
    reply(%{
      jsonrpc: "2.0",
      id: request["id"],
      error: %{code: -32601, message: "Method not found"}
    })
  end

  defp handle_tool_call(request_id, %{
         "name" => "fetch_livemd_outputs",
         "arguments" => %{"file_path" => file_path}
       }) do
    with {:ok, livebook_node} <- LivebookTools.Sync.discover_livebook_node(),
         true <- Node.connect(livebook_node),
         {:ok, livebook_pid} <-
           LivebookTools.Sync.find_livebook_session_pid_for_file(livebook_node, file_path),
         outputs <- LivebookTools.Sync.get_livemd_outputs(livebook_pid) do
      reply(%{
        jsonrpc: "2.0",
        id: request_id,
        result: %{
          content: [
            %{
              type: "text",
              text: outputs
            }
          ]
        }
      })
    else
      {:error, reason} ->
        reply(%{
          jsonrpc: "2.0",
          id: request_id,
          error: %{
            code: -32601,
            message: inspect(reason),
            data: %{name: "fetch_livemd_outputs"}
          }
        })
    end
  end

  defp reply(msg) do
    line =
      msg
      |> Jason.encode!()
      |> remove_non_ascii()

    tmpdir = System.tmp_dir()
    File.write(Path.join(tmpdir, "livebook_tools_mcp_server.log"), "REPLY: #{line}\n", [:append])
    IO.puts(line)
  end

  defp remove_non_ascii(data) when is_binary(data) do
    data
    |> String.codepoints()
    |> Enum.filter(fn char -> String.to_charlist(char) |> hd() < 128 end)
    |> Enum.join("")
  end

  defp get_line() do
    case IO.gets("") do
      :eof ->
        :eof

      line when is_binary(line) ->
        tmpdir = System.tmp_dir()
        File.write(Path.join(tmpdir, "livebook_tools_mcp_server.log"), "RECV: #{line}", [:append])
        Jason.decode(line)
    end
  end
end
