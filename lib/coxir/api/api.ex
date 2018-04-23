defmodule Coxir.API do
  @moduledoc """
  Used to interact with Discord's API while
  keeping track of all the ratelimits.
  """

  alias Coxir.API.Base

  defmodule Request do
    defstruct [:method, :route, body: "", options: [], headers: []]
  end

  def start do
    Swarm.register_name(__MODULE__, Coxir.API.Server, :start_link, [__MODULE__])
  end

  def request(method, route, body \\ "", options \\ [], headers \\ []) do
    GenServer.call({:via, :swarm, Coxir.API},
    {:request, %Request{
      method: method, 
      route: route,
      body: body,
      options: options,
      headers: headers}})
  end

  defmodule Server do
    use GenServer
    require Logger
    alias HTTPoison.{AsyncResponse,AsyncStatus,AsyncHeaders,AsyncChunk,AsyncEnd}
    
    def init([name]) do
      {:ok, {name, Map.new, :ets.new(:rates, [:set])}}
    end

    def start_link do
      GenServer.start_link(__MODULE__, [__MODULE__], name: __MODULE__)
    end

    def start_link(name) do
      GenServer.start_link(__MODULE__, [name], name: name)
    end

    def handle_call(:ping, from, state) do
      {:reply, :pong, state}
    end

    def handle_call({:request, %Request{method: method, route: route} = request}, from, {name, pending, limits}) do
      route
      |> route_param
      |> route_limit(limits)
      |> case do
        nil ->
          Process.send(self, {:request, route_param(route), from, request}, [])
          {:noreply, {name, pending, limits}}
        limit ->
          Process.send_after(self, {:request, route_param(route), from, request}, limit)
          {:noreply, {name, pending, limits}}
        end
    end

    def handle_call(misc, pid, state) do
      Logger.error("#{inspect pid} -> RestGateway: #{inspect misc}")
      {:noreply, state}
    end

    def handle_info({:request, route, from, %Request{} = request}, {name, pending, limits}) do
        %AsyncResponse{id: id}
          = Base.request!(
              request.method,
              request.route,
              request.body,
              request.headers,
              Keyword.put(request.options, :stream_to, self))
        {:noreply, {name, Map.put(pending, id, {route, from}), limits}}
    end
    
    def handle_info(%AsyncStatus{code: code, id: id}, {name, pending, limits} = state) do
      cond do
        code in [204] ->
          case Map.get(id, pending) do
            {_route, pid} -> 
              GenServer.reply(pid, :ok)
              {:noreply, {name, Map.delete(pending, id), limits}}
            true ->
              Logger.error("RestGateway: no pid for #{inspect id}")
              {:noreply, state}
          end
        code >= 400 and code < 500 ->
          {:noreply, {name, Map.update!(pending, id, &({&1, :error})), limits}}
        true ->
          {:noreply, {name, Map.update!(pending, id, &({&1, :ok})), limits}}
      end
    end

    def handle_info(%AsyncHeaders{headers: headers, id: id}, {name, pending, limits} = state) do
      case Map.get(pending, id) do
        {{route, _pid}, _status} ->
          reset = Map.get(headers, "X-RateLimit-Reset")
          remaining = Map.get(headers, "X-RateLimit-Remaining")
          {route, reset, remaining} = 
           headers["X-RateLimit-Global"]
           |> case do
             nil ->
               {route, reset, remaining}
             _global ->
               retry = headers["Retry-After"]
               reset = current_time() + retry
               {:global, reset, 0}
           end

          if reset && remaining do
            remote = headers["Date"]
            |> date_header

            offset = (remote - current_time())

            {route, remaining, reset + offset}
            |> update_limit(limits)
          end
        {route, _pid} ->
          Logger.error("RestGateway: Status not recieved for #{inspect id}")
          reset = Map.get(headers, "X-RateLimit-Reset")
          remaining = Map.get(headers, "X-RateLimit-Remaining")
          {route, reset, remaining} = 
           headers["X-RateLimit-Global"]
           |> case do
             nil ->
               {route, reset, remaining}
             _global ->
               retry = headers["Retry-After"]
               reset = current_time() + retry
               {:global, reset, 0}
           end

          if reset && remaining do
            remote = headers["Date"]
            |> date_header

            offset = (remote - current_time())

            {route, remaining, reset + offset}
            |> update_limit(limits)
          end
        true ->
          Logger.debug("RestGateway: Missing pid for #{inspect id}")
      end
      {:noreply, state}
    end

    def handle_info(%AsyncChunk{chunk: chunk, id: id}, {name, pending, limits} = state) do
      case Map.get(pending, id) do
        {{route, pid}, status} ->
          {:noreply, {name, Map.put(pending, id, {{route, pid}, status, chunk}), limits}}
        {{route, pid}, status, chunks} ->
          {:noreply, {name, Map.put(pending, id, {{route, pid}, status, chunks <> chunk}), limits}}
        {route, pid} ->
          Logger.debug("RestGateway: Missing status for #{inspect id}, treating as ok")
          {:noreply, {name, Map.put(pending, id, {{route, pid}, :ok, chunk}), limits}}
        true -> 
          Logger.error("RestGateway: Missing pid for #{inspect id}")
          {:noreply, state}
      end
    end

    def handle_info(%AsyncEnd{id: id}, {name, pending, limits}) do
      case Map.get(pending, id) do
        {{route, pid}, status, chunks} ->
          GenServer.reply(pid, chunks |> Coxir.API.Base.process_response_body)
        {{route, pid}, status} ->
          GenServer.reply(pid, status)
        {route, pid} ->
          Logger.error("RestGateway: Missing response for #{inspect id}")
      end
      {:noreply, {name, Map.delete(pending, id), limits}}
    end

    def handle_info(misc, state) do
      Logger.info("RestGateway: #{inspect misc}")
      {:noreply, state}
    end

    defp route_limit(route, table) do
      remaining = route
      |> count_limit(table)
      |> case do
        false ->
          route = :global
          count_limit(route, table)
          |> case do
            false -> 0
            count -> count
          end
        count ->
          count
      end

      cond do
        remaining < 0 ->
          case :ets.lookup(table, route) do
            [{_route, _remaining, reset}] ->
              left = reset - current_time()
              if left > 0 do
                left
              else
                :ets.delete(table, route)
                nil
              end
          end
        true -> nil
      end
    end

    defp count_limit(route, table) do
      try do
        :ets.update_counter(table, route, {2, -1})
      rescue
        _ -> false
      end
    end

    defp update_limit({route, remaining, reset}, table) do
      # update: {route, remaining, reset}
      # stored: {index, _remaining, saved}
      # when index == route and reset > saved -> update
      # replaces the stored limit info when both guards are met
      fun = \
      [{
        {:"$1", :"$2", :"$3"},
        [{
          :andalso,
          {:==, :"$1", route},
          {:>, :"$3", reset}
        }],
        [{
          {route, remaining, reset}
        }]
      }]
      try do
        :ets.select_replace(table, fun)
      rescue
        _ -> \
        :ets.insert_new(table, {route, remaining, reset})
      end
    end

    defp current_time do
      DateTime.utc_now
      |> DateTime.to_unix(:milliseconds)
    end

    defp route_param(route) do
      ~r/(channels|guilds)\/([0-9]{15,})+/i
      |> Regex.run(route)
      |> case do
        [match, _route, _param] ->
          match
        nil ->
          route
      end
    end

    defp date_header(header) do
      header
      |> String.to_charlist
      |> :httpd_util.convert_request_date
      |> :calendar.datetime_to_gregorian_seconds
      |> :erlang.-(62_167_219_200)
      |> :erlang.*(1000)
    end
  end
end