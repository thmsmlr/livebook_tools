defmodule LivebookTools.MCPServer do
  @moduledoc """
  Starts the MCP server running on STDIN/STDOUT.
  """

  def start() do
    with :ok <- expect_initialize() do
      handle_request_loop()
    end
  end

  defp handle_request_loop do
    with {:ok, request} <- get_line() do
      try do
        handle_request(request)
      rescue
        error ->
          IO.puts(:stderr, "Error: #{inspect(error)}")

          reply(%{
            jsonrpc: "2.0",
            id: request["id"],
            error: %{
              code: -32603,
              message: "Internal error"
            }
          })
      end
    end

    handle_request_loop()
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
                  description: "The path to the livemd file for the Livebook"
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

  defp handle_request(%{"method" => "tools/call", "id" => request_id, "params" => params}) do
    try do
      handle_tool_call(request_id, params)
    rescue
      error ->
        IO.puts(:stderr, "Error: #{inspect(error)}")

        reply(%{
          jsonrpc: "2.0",
          id: request_id,
          error: %{code: -32603, message: inspect(error)}
        })
    end
  end

  defp handle_request(%{"method" => "notifications/initialized"}) do
    :ok
  end

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
        IO.puts(:stderr, "Error: #{inspect(reason)}")

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

  defp expect_initialize() do
    case get_line() do
      {:ok, %{"method" => "initialize", "id" => id}} ->
        Livebook.Storage.start_link([])

        reply(%{
          jsonrpc: "2.0",
          id: id,
          result: %{
            protocolVersion: "2024-11-05",
            capabilities: %{
              logging: %{},
              prompts: %{},
              resources: %{},
              tools: %{
                listChanged: true
              }
            },
            serverInfo: %{
              name: "LivebookTools MCP Server",
              version: "0.0.1"
            }
          }
        })

      _ ->
        raise "Expected initialize message"
    end
  end

  defp reply(msg) do
    line = Jason.encode!(msg)
    tmpdir = System.tmp_dir()
    File.write(Path.join(tmpdir, "livebook_tools_mcp_server.log"), "REPLY: #{line}\n", [:append])
    IO.puts(line)
  end

  defp get_line() do
    line = IO.gets("")
    tmpdir = System.tmp_dir()
    File.write(Path.join(tmpdir, "livebook_tools_mcp_server.log"), "RECV: #{line}", [:append])
    Jason.decode(line)
  end
end
