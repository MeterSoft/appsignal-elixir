defmodule Appsignal do
  @moduledoc """
  AppSignal for Elixir. Follow the [installation
  guide](https://docs.appsignal.com/elixir/installation.html) to install
  AppSignal into your Elixir app.

  This module contains the main AppSignal OTP application, as well as a few
  helper functions for sending metrics to AppSignal.

  These metrics do not rely on an active transaction being present. For
  transaction related-functions, see the
  [Appsignal.Transaction](Appsignal.Transaction.html) module.
  """

  use Application
  alias Appsignal.Config
  require Logger

  @doc false
  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    initialize()

    Appsignal.Error.Backend.attach()
    Appsignal.Ecto.attach()

    children = [
      {Appsignal.Tracer, []},
      {Appsignal.Monitor, []},
      {Appsignal.Probes, []}
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Appsignal.Supervisor)

    # Add our default system probes. It's important that this is called after
    # the Suportvisor has started. Otherwise the GenServer cannot register the
    # probe.
    add_default_probes()

    result
  end

  @doc false
  def stop(_state) do
    Logger.debug("AppSignal stopping.")
  end

  @doc false
  def config_change(_changed, _new, _removed) do
    # Spawn a separate process that reloads the configuration. AppSignal can't
    # reload it in the same process because the GenServer would continue
    # calling itself once it reached `Application.put_env` in
    # `Appsignal.Config`.
    spawn(fn ->
      :ok = Appsignal.Nif.stop()
      :ok = initialize()
    end)
  end

  @doc false
  def initialize do
    case {Config.initialize(), Config.configured_as_active?()} do
      {_, false} ->
        Logger.info("AppSignal disabled.")

      {:ok, true} ->
        Logger.debug("AppSignal starting.")
        Config.write_to_environment()
        Appsignal.Nif.start()

        if Appsignal.Nif.loaded?() do
          Logger.debug("AppSignal started.")
        else
          Logger.error(
            "Failed to start AppSignal. Please run the diagnose task " <>
              "(https://docs.appsignal.com/elixir/command-line/diagnose.html) " <>
              "to debug your installation."
          )
        end

      {{:error, :invalid_config}, true} ->
        Logger.warn(
          "Warning: No valid AppSignal configuration found, continuing with " <>
            "AppSignal metrics disabled."
        )
    end
  end

  @doc false
  def add_default_probes do
    Appsignal.Probes.register(:erlang, &Appsignal.Probes.ErlangProbe.call/0)
  end

  @doc """
  Set a gauge for a measurement of a metric.
  """
  @spec set_gauge(String.t(), float | integer, map) :: :ok
  def set_gauge(key, value, tags \\ %{})

  def set_gauge(key, value, tags) when is_integer(value) do
    set_gauge(key, value + 0.0, tags)
  end

  def set_gauge(key, value, %{} = tags) when is_float(value) do
    encoded_tags = Appsignal.Utils.DataEncoder.encode(tags)
    :ok = Appsignal.Nif.set_gauge(key, value, encoded_tags)
  end

  @doc """
  Increment a counter of a metric.
  """
  @spec increment_counter(String.t(), number, map) :: :ok
  def increment_counter(key, count \\ 1, tags \\ %{})

  def increment_counter(key, count, %{} = tags) when is_number(count) do
    encoded_tags = Appsignal.Utils.DataEncoder.encode(tags)
    :ok = Appsignal.Nif.increment_counter(key, count + 0.0, encoded_tags)
  end

  @doc """
  Add a value to a distribution

  Use this to collect multiple data points that will be merged into a graph.
  """
  @spec add_distribution_value(String.t(), float | integer, map) :: :ok
  def add_distribution_value(key, value, tags \\ %{})

  def add_distribution_value(key, value, tags) when is_integer(value) do
    add_distribution_value(key, value + 0.0, tags)
  end

  def add_distribution_value(key, value, %{} = tags) when is_float(value) do
    encoded_tags = Appsignal.Utils.DataEncoder.encode(tags)
    :ok = Appsignal.Nif.add_distribution_value(key, value, encoded_tags)
  end

  defdelegate instrument(fun), to: Appsignal.Instrumentation
  defdelegate instrument(name, fun), to: Appsignal.Instrumentation
  defdelegate instrument(name, category, fun), to: Appsignal.Instrumentation
  defdelegate set_error(kind, reason, stacktrace), to: Appsignal.Instrumentation
  defdelegate send_error(kind, reason, stacktrace), to: Appsignal.Instrumentation
end
