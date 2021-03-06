defmodule Coxir do
  @moduledoc """
  When *used*, this module defines a `start_link/0` callback
  responsible for starting a `Consumer` process. This process
  then consumes events from the GenStage and then dispatches
  them onto the handling module.

  Essentially that-is `Consumer` is provided with the module's
  reference the `start_link` callback was defined on, and thus is
  then able to call the custom handling methods that one may
  define based on their needs.

  Additionally, aliases to all the structures as well as to other
  crucial modules are included when *used*.
  """

  use Application
  use Supervisor

  alias Coxir.{API, Struct}
  alias Coxir.{Voice, Stage, Gateway}

  @doc false
  def start(_type, _args) do
    children = [
    ]
    options = [
      strategy: :one_for_one,
      name: __MODULE__
    ]
    start
    Supervisor.start_link(children, options)
  end

  def start do
    Coxir.Struct.Message.start 5
    Coxir.Tracker.start
    Coxir.Gateway.start 1
  end

  @doc false
  def child_spec(arg),
    do: super(arg)

  defmacro __using__(_opts) do
    quote do
      alias Coxir.Struct.{User, Invite}
      alias Coxir.Struct.{Guild, Role, Member, Integration}
      alias Coxir.Struct.{Channel, Overwrite, Message, Webhook}
      alias Coxir.{Voice, Gateway, API}

      def start_link do
        Coxir.Stage.Consumer.start_link __MODULE__
      end

      def handle_event(_event, state) do
        {:ok, state}
      end

      defoverridable [handle_event: 2]
    end
  end
end
