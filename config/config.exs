import Config
# Default, required config for Livebook
config :livebook,
  agent_name: "default",
  allowed_uri_schemes: [],
  app_service_name: nil,
  app_service_url: nil,
  authentication: {:password, "nerves"},
  aws_credentials: false,
  feature_flags: [],
  force_ssl_host: nil,
  plugs: [],
  rewrite_on: [],
  teams_auth?: false,
  teams_url: "https://teams.livebook.dev",
  github_release_info: %{
    repo: "nerves-livebook/nerves_livebook",
    version: Mix.Project.config()[:version]
  },
  update_instructions_url: nil,
  within_iframe: false

config :livebook, Livebook.Apps.Manager, retry_backoff_base_ms: 5_000

# Configure MIME types for SSE
config :mime, :types, %{
  "text/event-stream" => ["sse"]
}

# Configure the MCP Server
config :mcp_sse, :mcp_server, LivebookTools.MCP.Server
