defmodule Coxir.Gateway do
  defmodule Worker do
    require Logger
    use WebSockex

    defmodule State do
      defstruct [
        :token,
        heartbeat_interval: 5000,
        sequence: 0,
        id: 0,
        shards: 1
      ]
    end

    def start_link(url, state) do
      WebSockex.start_link(url, __MODULE__, state)
    end

    def handle_frame({:binary, msg}, state) do
      packet = :erlang.binary_to_term(msg)
      next_state = case packet.op do
        10 ->
          Logger.debug("Coxir.Gateway: Connected to #{inspect packet.d._trace}")
          Process.send(self, {:send,
          :binary,
          payload(%{
            "token" => state.token,
            "properties" => %{
              "$os" => "linux",
              "$device" => "coxir",
              "$browser" => "coxir"
            },
            "compress" => false,
            "large_threshold" => 250,
            "shard" => [state.id, state.shards]
          }, 2)
          }, [])
          Process.send(self, :heartbeat, [])
          {:ok, %{state | heartbeat_interval: packet.d.heartbeat_interval, sequence: packet.s}}
        9 -> 
          Process.send(self, {:send,
          :binary,
          payload(%{
            "token" => state.token,
            "properties" => %{
              "$os" => "linux",
              "$device" => "coxir",
              "$browser" => "coxir"
            },
            "compress" => false,
            "large_threshold" => 250,
            "shard" => [state.id, state.shards]
          }, 2)
          }, [])
          {:ok, %{state | sequence: packet.s}}
        0 ->
          Swarm.publish(packet.t, {packet.t, packet.d |> Enum.reduce(%{}, fn({key, val}, acc)
            -> Map.put(acc, if is_binary(key) do String.to_atom(key) else key end, val) end)})
        1 ->
          Process.send(self, {:send, :binary, payload(packet.s, 1)}, [])
          {:ok, %{state | sequence: packet.s}}
        11 ->
          {:ok, state}
        _ ->
          Logger.debug("Coxir.Gateway<#{state.id}>: Opcode fallthrough: #{inspect packet}")
          {:ok, %{state | sequence: packet.s}}
      end
    end

    def handle_frame({type, msg}, state) do
      Logger.debug("Coixr.Gateway<#{state.id}>: #{inspect type}, #{inspect msg}")
      {:ok, state}
    end

    def handle_info({:"$gen_call", pid, :shard}, state) do
      GenServer.reply(pid, String.to_atom "gateway_#{inspect state.id}")
      {:ok, state}
    end

    def handle_info({:send, type, msg}, state) do
      {:reply, {type, msg}, state}
    end

    def handle_info(:heartbeat, %State{heartbeat_interval: heartbeat, sequence: seq} = state) do
      Logger.debug("Coxir.Gateway<#{state.id}>: heartbeat #{inspect seq}")
      Process.send_after(self, :heartbeat, heartbeat)
      {:reply, {:binary, payload(seq, 1)}, state}
    end

    def payload(data, op) do
      %{"op" => op, "d" => data}
      |> :erlang.term_to_binary
    end
  end

  def start(nprocs) do
    for n <- 0..nprocs-1 do
      name = :"gateway_#{inspect n}"
      {:ok, pid} = Swarm.register_name(name, __MODULE__, :register, [nprocs, n])
      Swarm.join(:gateway, pid)
    end
  end

  def register(shards, shard) do
    token = Application.get_env(:coxir, :token)
    if !token, do: raise "Please provide a token."
    Worker.start_link("wss://gateway.discord.gg/?v=6&encoding=etf", %Worker.State{
      token: token,
      shards: shards,
      id: shard
    })
  end
  
  def get(shard) when is_integer(shard) do
    String.to_atom("gateway_#{inspect shard}")
  end
end