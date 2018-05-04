defmodule Coxir.Tracker do
    use GenServer

    def start do
        Swarm.register_name(:tracker, __MODULE__, :run, [nil], 5000)
        :ok
    end

    def run(nil) do
        GenServer.start_link(__MODULE__, [])
    end

    def handle_info({:MESSAGE_CREATE, message}, state) do
        Coxir.Struct.Message.update(message)
        {:noreply, state}
    end

    def handle_info({:MESSAGE_EDIT, message}, state) do
        Coxir.Struct.Message.update(message)
        {:noreply, state}
    end

    def handle_info(:ready, state) do
        Swarm.join(:MESSAGE_CREATE, self)
        Swarm.join(:MESSAGE_EDIT, self)
        {:noreply, state}
    end

    def init([]) do
        send(self, :ready)
        {:ok, nil}
    end
end