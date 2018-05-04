defmodule Coxir.Struct do
  @moduledoc false

  defmacro __using__(_opts) do
    quote location: :keep do
      alias Coxir.API
      use GenServer
      use Bitwise

      @name __MODULE__
      |> Module.split
      |> List.last
      |> String.downcase
      |> String.to_atom

      def creation_time(id) when is_integer(id) do
        ( id >>> 22 ) + 1420070400000
      end

      defp get_timeout do
        Application.get_env(:coxir, :timeout)
        |> case do
          %{@name => timeout} when is_integer(timeout) ->
            timeout
          timeout when is_integer(timeout) ->
            timeout
          _ -> 24 * 60 * 60 * 1000
        end
      end

      defp put(map, key, value) do
        case map do
          %{error: _error} ->
            map
          _object ->
            Map.put(map, key, value)
        end
      end

      defp replace(map, key, function) do
        map
        |> Map.get(key)
        |> case do
          nil -> nil
          list when is_list(list) ->
            Enum.map(list, function)
          value ->
            function.(value)
        end
        |> case do
          nil ->
            map
          value ->
            new = key
            |> Atom.to_string
            |> String.replace_trailing("_id", "")
            |> String.to_atom

            Map.put(map, new, value)
        end
      end

      @doc false
      def pretty(struct), do: struct

      def call_shard(id, call) do
        shard_name = &( GenServer.call({:via, :swarm, :"#{@name}_#{inspect &1}"}, call))
        shards = length(Swarm.members(__MODULE__))
        (id >>> 22)
        |> rem(shards)
        |> shard_name.()
      end

      def start(nproc) when is_integer(nproc) do
        for n <- 0..nproc-1 do
          pid = case Swarm.register_name(:"#{@name}_#{inspect n}", __MODULE__, :start, []) do
            {:ok, pid} -> pid
            {:error, {:already_started, pid}} -> pid
            nil -> nil
          end
          Swarm.join(__MODULE__, pid)
        end
      end

      def start do
        GenServer.start_link(__MODULE__, [], [])
      end

      def init([]) do
        Process.send(self, :prune, [])
        {:ok, :ets.new(__MODULE__, [:set])}
      end

      def get(%{id: id}), do: get(id)
      def get(id) do
        call_shard(id, {:get, id})
      end

      def update(%{id: id} = data) do
        call_shard(id, {:update, data})
      end

      def select(pattern \\ %{}) do
        Swarm.multi_call(__MODULE__, {:select, pattern})
        |> Enum.concat
      end

      def parse_pattern(list, caller) do
        GenServer.reply(caller, list |> Enum.to_list)
      end

      def handle_info(:prune, ets) do
        recent_allowed = ((DateTime.utc_now |> DateTime.to_unix(:millisecond)) - get_timeout - 1420070400000) <<< 22
        n = :ets.select_delete(ets, [{{:_, %{id: :"$1"}}, [{:<, :"$1", {:const, recent_allowed}}], [:true]}])
        Logger.debug("#{inspect n} #{@name} deleted")
        Process.send_after(self, :prune, 60_000)
        {:noreply, ets}
      end

      def handle_call({:update, %{id: id} = data}, _from, ets) do
        {:reply,
        :ets.insert(ets,
          {id, case :ets.lookup(ets, id) do
            [entry] -> Map.merge(data, entry)
            [] -> data
          end}),
          ets}
      end

      def handle_call({:select, pattern}, from, ets) when is_function(pattern, 1) do
        Task.start(
          fn() ->
            GenServer.reply(from, :ets.select(ets, :ets.fun2ms(pattern)))
          end
          )
        {:noreply, ets}
      end

      def handle_call({:select, pattern}, from, ets) do
        stream = :ets.tab2list(ets)
        |> Stream.filter(
          fn struct ->
            pattern
            |> Map.to_list
            |> Enum.filter(
              fn {key, value} ->
                struct
                |> Map.get(key)
                != value
              end
            )
            |> length
            == 0
          end)
        Swarm.register_name(
          :"#{@name}_select_#{String.slice(inspect(:rand.uniform), 2, 64)}",
          __MODULE__, :parse_pattern, [stream, from])
        {:noreply, ets}
      end

      def handle_call({:get, id}, _from, ets) do
        entry = case :ets.lookup(ets, id) do
          [entry] -> entry
          [] -> nil
        end
        {:reply, entry, ets}
      end
      defoverridable [init: 1]
      defoverridable [get: 1]
      defoverridable [pretty: 1]
    end
  end
end
