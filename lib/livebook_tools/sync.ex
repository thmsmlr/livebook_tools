defmodule LivebookTools.Sync do
  def find_livebook_session_pid_for_file(node, file_path) do
    :rpc.call(node, Code, :eval_quoted, [
      quote do
        :erlang.processes()
        |> Enum.filter(fn pid ->
          info = Process.info(pid)

          case info[:dictionary][:"$initial_call"] do
            {Livebook.Session, _, _} -> true
            _ -> false
          end
        end)
        |> Enum.find_value(fn pid ->
          state = :sys.get_state(pid)

          if state.data.file.path == unquote(file_path) do
            pid
          end
        end)
      end
    ])
    |> case do
      {pid, _} when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :no_livebook_session}
    end
  end

  def discover_livebook_node do
    # Get all registered names from the Erlang Port Mapper Daemon
    case :erl_epmd.names() do
      {:ok, names} ->
        discovered_node =
          Enum.find_value(names, fn {name, _port} ->
            node_name = "#{name}@127.0.0.1" |> String.to_atom()
            was_connected = Node.list(:connected) |> Enum.member?(node_name)
    
            with true <- Node.connect(node_name) do
              # Scan for Livebook processes
              livebook_processes =
                :rpc.call(node_name, :erlang, :registered, [])
                |> Enum.filter(fn proc ->
                  to_string(proc) =~ "Livebook.Session"
                end)
    
              # Disconnect if we weren't connected before
              if not was_connected do
                Node.disconnect(node_name)
              end
    
              # Return the node if it has Livebook processes
              if livebook_processes != [], do: node_name, else: nil
            end
          end)
    
        case discovered_node do
          nil -> {:error, :no_livebook_node}
          discovered_node when is_atom(discovered_node) -> {:ok, discovered_node}
        end

      {:error, reason} ->
        raise "No livebook node found: #{inspect(reason)}"
    end
  end

  def get_livemd_outputs(livebook_pid) do
    state = :sys.get_state(livebook_pid)
    notebook = state.data.notebook

    [notebook.setup_section | notebook.sections]
    |> Enum.flat_map(& &1.cells)
    |> Enum.map(fn
      %Livebook.Notebook.Cell.Code{source: source, language: language, outputs: outputs} ->
        outputs = Enum.map(outputs, fn {_idx, output} -> output end)

        """
        ```#{language}
        #{source}
        ```

        ```outputs
        #{inspect(outputs, pretty: true, width: 0)}
        ```
        """

      _ ->
        ""
    end)
    |> Enum.join("\n")
  end

  def cells(livebook_pid) do
    state = :sys.get_state(livebook_pid)
    cells = state.data.notebook.sections |> Enum.flat_map(& &1.cells)
    state.data.notebook.setup_section.cells ++ cells
  end

  def cells_from_livemd(file_path) do
    file_path
    |> File.read!()
    |> Livebook.LiveMarkdown.notebook_from_livemd()
    |> then(fn {notebook, _} ->
      notebook.sections |> Enum.flat_map(& &1.cells)
    end)
  end

  def get_current_revision(livebook_pid, cell_id) do
    :sys.get_state(livebook_pid)
    |> get_in(
      [:data, :cell_infos, cell_id, :sources, :primary, :revision]
      |> Enum.map(&Access.key!(&1))
    )
  end

  def update_cell(livebook_pid, cell_id, new_source) do
    revision = get_current_revision(livebook_pid, cell_id)
    current_cell = cells(livebook_pid) |> Enum.find(&(&1.id == cell_id))
    current_source = current_cell.source

    GenServer.cast(
      livebook_pid,
      {:apply_cell_delta, self(), cell_id, :primary,
       %Livebook.Text.Delta{
         ops: [
           {:delete, current_source |> String.length()},
           {:insert, new_source}
         ]
       }, nil, revision}
    )
  end

  def insert_cell(livebook_pid, new_cell, section_id, before_cell_id) do
    state = :sys.get_state(livebook_pid)
    section = state.data.notebook.sections |> Enum.find(&(&1.id == section_id))

    cell_idx =
      if before_cell_id == nil,
        do: section.cells |> length(),
        else: section.cells |> Enum.find_index(&(&1.id == before_cell_id))

    if section do
      type = Livebook.Notebook.Cell.type(new_cell)

      attrs =
        case type do
          :code ->
            %{
              source: new_cell.source,
              language: new_cell.language
            }

          _ ->
            %{
              source: new_cell.source
            }
        end

      GenServer.cast(
        livebook_pid,
        {:insert_cell, self(), section_id, cell_idx, type, attrs}
      )
    else
      raise "Section not found for cell: #{inspect(before_cell_id)}"
    end
  end

  def delete_cell(livebook_pid, cell_id) do
    GenServer.cast(livebook_pid, {:delete_cell, self(), cell_id})
  end

  def edit_script(before_list, after_list, opts \\ []) do
    key_fn = opts[:key_fn] || fn x -> x end

    before_keys = before_list |> Enum.map(key_fn)
    after_keys = after_list |> Enum.map(key_fn)

    List.myers_difference(before_keys, after_keys)
    |> Enum.flat_map(fn
      {tag, xs} -> xs |> Enum.map(&{tag, &1})
    end)
    |> Enum.reduce([], fn
      {:ins, y}, [{:del, x} | rest] -> [{:upd, {x, y}} | rest]
      elem, acc -> [elem | acc]
    end)
    |> Enum.reverse()
    |> Enum.reduce({before_list, after_list, []}, fn
      {:eq, _}, {[before_elem | before_list], [after_elem | after_list], acc} ->
        {before_list, after_list, [{:eq, {before_elem, after_elem}} | acc]}

      {:upd, _}, {[before_elem | before_list], [after_elem | after_list], acc} ->
        {before_list, after_list, [{:upd, {before_elem, after_elem}} | acc]}

      {:del, _}, {[before_elem | before_list], after_list, acc} ->
        {before_list, after_list, [{:del, before_elem} | acc]}

      {:ins, _}, {[], [after_elem | after_list], acc} ->
        {[], after_list, [{:ins, after_elem, nil} | acc]}

      {:ins, _}, {[before_elem | before_list], [after_elem | after_list], acc} ->
        {[before_elem | before_list], after_list, [{:ins, after_elem, before_elem} | acc]}
    end)
    |> elem(2)
    |> Enum.reverse()
  end

  def sync(livebook_pid, file_path) do
    sync_notebook_name(livebook_pid, file_path)
    sync_setup_cell(livebook_pid, file_path)
    sync_sections(livebook_pid, file_path)
    sync_cells(livebook_pid, file_path)
  end

  def sync_notebook_name(livebook_pid, file_path) do
    current_notebook =
      :sys.get_state(livebook_pid)
      |> get_in([:data, Access.key!(:notebook)])

    new_notebook =
      file_path
      |> File.read!()
      |> Livebook.LiveMarkdown.notebook_from_livemd()
      |> elem(0)

    if current_notebook.name != new_notebook.name do
      Livebook.Session.set_notebook_name(livebook_pid, new_notebook.name)
    end
  end

  def sync_setup_cell(livebook_pid, file_path) do
    current_setup_section =
      :sys.get_state(livebook_pid)
      |> get_in([:data, Access.key!(:notebook), Access.key!(:setup_section)])

    new_setup_section =
      file_path
      |> File.read!()
      |> Livebook.LiveMarkdown.notebook_from_livemd()
      |> elem(0)
      |> Map.get(:setup_section)

    [current_setup_cell | _] = current_setup_section.cells
    [new_setup_cell | _] = new_setup_section.cells

    if new_setup_cell.source != current_setup_cell.source do
      update_cell(livebook_pid, current_setup_cell.id, new_setup_cell.source)
    end
  end

  def sync_sections(livebook_pid, file_path) do
    current_sections =
      :sys.get_state(livebook_pid)
      |> get_in([:data, Access.key!(:notebook), Access.key!(:sections)])

    new_sections =
      file_path
      |> File.read!()
      |> Livebook.LiveMarkdown.notebook_from_livemd()
      |> elem(0)
      |> Map.get(:sections)

    edit_script(current_sections, new_sections, key_fn: & &1.name)
    |> Enum.each(fn
      {:eq, {_current_section, _new_section}} ->
        :ok

      {:upd, {current_section, new_section}} ->
        Livebook.Session.set_section_name(livebook_pid, current_section.id, new_section.name)

      {:del, current_section} ->
        Livebook.Session.delete_section(livebook_pid, current_section.id, false)

      {:ins, new_section, before_section} ->
        before_section_idx =
          if before_section do
            current_sections |> Enum.find_index(&(&1.id == before_section.id))
          else
            length(current_sections) - 1
          end

        Livebook.Session.insert_section(livebook_pid, before_section_idx)

        placeholder_section =
          :sys.get_state(livebook_pid)
          |> get_in([:data, Access.key!(:notebook), Access.key!(:sections)])
          |> Enum.at(before_section_idx)

        Livebook.Session.set_section_name(livebook_pid, placeholder_section.id, new_section.name)
    end)
  end

  def sync_cells(livebook_pid, file_path) do
    current_sections =
      :sys.get_state(livebook_pid)
      |> get_in([:data, Access.key!(:notebook), Access.key!(:sections)])

    new_sections =
      file_path
      |> File.read!()
      |> Livebook.LiveMarkdown.notebook_from_livemd()
      |> elem(0)
      |> Map.get(:sections)

    List.myers_difference(
      current_sections,
      new_sections,
      fn current_section, new_section ->
        edit_script(
          current_section.cells,
          new_section.cells,
          key_fn: & &1.source
        )
      end
    )
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:diff, diff_script}, section_idx} ->
        current_section = current_sections |> Enum.at(section_idx)
        diff_script |> Enum.map(&{&1, current_section})

      {{:del, _}, section_idx} ->
        current_section = current_sections |> Enum.at(section_idx)
        Livebook.Session.delete_section(livebook_pid, current_section.id, false)
        []

    end)
    |> Enum.each(fn
      {{:eq, {_current_cell, _new_cell}}, _section} ->
        :ok

      {{:upd, {current_cell, new_cell}}, _section} ->
        update_cell(livebook_pid, current_cell.id, new_cell.source)

      {{:ins, new_cell, before_cell}, section} ->
        before_cell_id = if before_cell, do: before_cell.id, else: nil
        insert_cell(livebook_pid, new_cell, section.id, before_cell_id)

      {{:del, current_cell}, _section} ->
        delete_cell(livebook_pid, current_cell.id)

      x ->
        raise "Unknown change: #{inspect(x)}"
    end)
  end
end
