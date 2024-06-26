defmodule Klife.Producer.Controller do
  use GenServer

  import Klife.ProcessRegistry

  alias Klife.PubSub

  alias KlifeProtocol.Messages
  alias Klife.Connection.Broker
  alias Klife.Connection.Controller, as: ConnController
  alias Klife.Utils
  alias Klife.Producer.ProducerSupervisor

  alias Klife.TxnProducerPool

  alias Klife.Producer

  @default_producer %{name: :klife_default_producer}

  @default_txn_pool %{name: :klife_txn_pool}

  @check_metadata_delay :timer.seconds(10)

  @txn_pool_options [
    name: [type: :atom, required: true, default: :klife_txn_pool],
    pool_size: [type: :non_neg_integer, default: 10],
    delivery_timeout_ms: [type: :non_neg_integer, default: :timer.seconds(30)],
    request_timeout_ms: [type: :non_neg_integer, default: :timer.seconds(15)],
    retry_backoff_ms: [type: :non_neg_integer, default: :timer.seconds(1)],
    txn_timeout_ms: [type: :non_neg_integer, default: :timer.seconds(60)],
    base_txn_id: [type: :string, default: ""],
    compression_type: [type: {:in, [:none, :gzip, :snappy]}, default: :none]
  ]

  defstruct [
    :cluster_name,
    :producers,
    :topics,
    :check_metadata_waiting_pids,
    :check_metadata_timer_ref,
    :txn_pools
  ]

  def start_link(args) do
    cluster_name = Keyword.fetch!(args, :cluster_name)

    validated_pool_args =
      args
      |> Keyword.get(:txn_pools, [])
      |> Enum.concat([@default_txn_pool])
      |> Enum.map(fn pool_config ->
        pool_config
        |> Map.to_list()
        |> NimbleOptions.validate!(@txn_pool_options)
        |> Map.new()
      end)

    validated_args = Keyword.put(args, :txn_pools, validated_pool_args)

    GenServer.start_link(__MODULE__, validated_args, name: via_tuple({__MODULE__, cluster_name}))
  end

  @impl true
  def init(args) do
    cluster_name = Keyword.fetch!(args, :cluster_name)
    topics_list = Keyword.get(args, :topics, [])

    timer_ref = Process.send_after(self(), :check_metadata, 0)

    state = %__MODULE__{
      cluster_name: cluster_name,
      producers: [@default_producer] ++ Keyword.get(args, :producers, []),
      txn_pools: Keyword.get(args, :txn_pools, []),
      topics: Enum.filter(topics_list, &Map.get(&1, :enable_produce, true)),
      check_metadata_waiting_pids: [],
      check_metadata_timer_ref: timer_ref
    }

    Enum.each(topics_list, fn t ->
      :persistent_term.put(
        {__MODULE__, cluster_name, t.name},
        Map.get(t, :producer, @default_producer.name)
      )
    end)

    :ets.new(topics_partitions_metadata_table(cluster_name), [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    :ets.new(partitioner_metadata_table(cluster_name), [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    Utils.wait_connection!(cluster_name)

    :ok = PubSub.subscribe({:cluster_change, cluster_name})

    {:ok, state}
  end

  def handle_info(
        {{:cluster_change, cluster_name}, _event_data, _callback_data},
        %__MODULE__{cluster_name: cluster_name} = state
      ) do
    Process.cancel_timer(state.check_metadata_timer_ref)
    new_ref = Process.send_after(self(), :check_metadata, 0)

    {:noreply,
     %__MODULE__{
       state
       | check_metadata_timer_ref: new_ref
     }}
  end

  def handle_info(:handle_producers, %__MODULE__{} = state) do
    for producer <- state.producers do
      opts =
        producer
        |> Map.put(:cluster_name, state.cluster_name)
        |> Map.to_list()

      DynamicSupervisor.start_child(
        via_tuple({ProducerSupervisor, state.cluster_name}),
        {Producer, opts}
      )
      |> case do
        {:ok, _pid} -> :ok
        {:error, {:already_started, pid}} -> send(pid, :handle_batchers)
      end
    end

    send(self(), :handle_txn_producers)

    {:noreply, state}
  end

  def handle_info(:handle_txn_producers, %__MODULE__{} = state) do
    for txn_pool <- state.txn_pools,
        txn_producer_count <- 1..txn_pool.pool_size do
      txn_id =
        if txn_pool.base_txn_id != "" do
          txn_pool.base_txn_id <> "_#{txn_producer_count}"
        else
          :crypto.strong_rand_bytes(15)
          |> Base.url_encode64()
          |> binary_part(0, 15)
          |> Kernel.<>("_#{txn_producer_count}")
        end

      txn_producer_configs = %{
        cluster_name: state.cluster_name,
        name: :"klife_txn_producer.#{txn_pool.name}.#{txn_producer_count}",
        acks: :all,
        linger_ms: 0,
        delivery_timeout_ms: txn_pool.delivery_timeout_ms,
        request_timeout_ms: txn_pool.request_timeout_ms,
        retry_backoff_ms: txn_pool.retry_backoff_ms,
        max_in_flight_requests: 1,
        batchers_count: 1,
        enable_idempotence: true,
        compression_type: txn_pool.compression_type,
        txn_id: txn_id,
        txn_timeout_ms: txn_pool.txn_timeout_ms
      }

      DynamicSupervisor.start_child(
        via_tuple({ProducerSupervisor, state.cluster_name}),
        {Producer, Map.to_list(txn_producer_configs)}
      )
      |> case do
        {:ok, _pid} -> :ok
        {:error, {:already_started, pid}} -> send(pid, :handle_batchers)
      end
    end

    for txn_pool <- state.txn_pools do
      DynamicSupervisor.start_child(
        via_tuple({ProducerSupervisor, state.cluster_name}),
        {TxnProducerPool, Map.to_list(txn_pool) ++ [cluster_name: state.cluster_name]}
      )
      |> case do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        :check_metadata,
        %__MODULE__{cluster_name: cluster_name, topics: topics} = state
      ) do
    content = %{
      topics: Enum.map(topics, fn t -> %{name: t.name} end)
    }

    case Broker.send_message(Messages.Metadata, cluster_name, :controller, content) do
      {:error, _} ->
        :ok = ConnController.trigger_brokers_verification(cluster_name)
        new_ref = Process.send_after(self(), :check_metadata, :timer.seconds(1))
        {:noreply, %{state | check_metadata_timer_ref: new_ref}}

      {:ok, %{content: resp}} ->
        :ok = setup_producers(state, resp)
        :ok = setup_partitioners(state, resp)

        if Enum.any?(resp.topics, &(&1.error_code != 0)) do
          new_ref = Process.send_after(self(), :check_metadata, :timer.seconds(1))
          {:noreply, %{state | check_metadata_timer_ref: new_ref}}
        else
          state.check_metadata_waiting_pids
          |> Enum.reverse()
          |> Enum.each(&GenServer.reply(&1, :ok))

          new_ref = Process.send_after(self(), :check_metadata, @check_metadata_delay)

          {:noreply,
           %{state | check_metadata_timer_ref: new_ref, check_metadata_waiting_pids: []}}
        end
    end
  end

  # Public Interface

  def trigger_metadata_verification_sync(cluster_name) do
    GenServer.call(via_tuple({__MODULE__, cluster_name}), :trigger_check_metadata)
  end

  def trigger_metadata_verification_async(cluster_name) do
    GenServer.cast(via_tuple({__MODULE__, cluster_name}), :trigger_check_metadata)
  end

  def get_topics_partitions_metadata(cluster_name, topic, partition) do
    [{_key, broker_id, default_producer, batcher_id}] =
      cluster_name
      |> topics_partitions_metadata_table()
      |> :ets.lookup({topic, partition})

    %{
      broker_id: broker_id,
      producer_name: default_producer,
      batcher_id: batcher_id
    }
  end

  def get_broker_id(cluster_name, topic, partition) do
    cluster_name
    |> topics_partitions_metadata_table()
    |> :ets.lookup_element({topic, partition}, 2)
  end

  def get_default_producer(cluster_name, topic, partition) do
    cluster_name
    |> topics_partitions_metadata_table()
    |> :ets.lookup_element({topic, partition}, 3)
  end

  def get_batcher_id(cluster_name, topic, partition) do
    cluster_name
    |> topics_partitions_metadata_table()
    |> :ets.lookup_element({topic, partition}, 4)
  end

  def update_batcher_id(cluster_name, topic, partition, new_batcher_id) do
    cluster_name
    |> topics_partitions_metadata_table()
    |> :ets.update_element({topic, partition}, {4, new_batcher_id})
  end

  def get_all_topics_partitions_metadata(cluster_name) do
    cluster_name
    |> topics_partitions_metadata_table()
    |> :ets.tab2list()
    |> Enum.map(fn {{topic_name, partition_idx}, leader_id, _default_producer, batcher_id} ->
      %{
        topic_name: topic_name,
        partition_idx: partition_idx,
        leader_id: leader_id,
        batcher_id: batcher_id
      }
    end)
  end

  def get_producer_for_topic(cluster_name, topic),
    do: :persistent_term.get({__MODULE__, cluster_name, topic})

  def get_partitioner_data(cluster_name, topic) do
    cluster_name
    |> partitioner_metadata_table()
    |> :ets.lookup_element(topic, 2)
  end

  # Private functions

  defp setup_producers(%__MODULE__{} = state, resp) do
    %__MODULE__{
      cluster_name: cluster_name,
      topics: topics
    } = state

    table_name = topics_partitions_metadata_table(cluster_name)

    results =
      for topic <- Enum.filter(resp.topics, &(&1.error_code == 0)),
          config_topic = Enum.find(topics, &(&1.name == topic.name)),
          partition <- topic.partitions do
        case :ets.lookup(table_name, {topic.name, partition.partition_index}) do
          [] ->
            :ets.insert(table_name, {
              {topic.name, partition.partition_index},
              partition.leader_id,
              config_topic[:producer] || @default_producer.name,
              # batcher_id will be defined on producer
              nil
            })

            :new

          [{key, current_broker_id, _default_producer, _batcher_id}] ->
            if current_broker_id != partition.leader_id do
              :ets.update_element(
                table_name,
                key,
                {2, partition.leader_id}
              )

              :new
            else
              :noop
            end
        end
      end

    if Enum.any?(results, &(&1 == :new)) do
      send(self(), :handle_producers)
    end

    :ok
  end

  defp setup_partitioners(%__MODULE__{} = state, resp) do
    %__MODULE__{
      cluster_name: cluster_name,
      topics: topics
    } = state

    table_name = partitioner_metadata_table(cluster_name)

    for topic <- Enum.filter(resp.topics, &(&1.error_code == 0)),
        config_topic = Enum.find(topics, &(&1.name == topic.name)) do
      max_partition =
        topic.partitions
        |> Enum.map(& &1.partition_index)
        |> Enum.max()

      data = %{
        max_partition: max_partition,
        default_partitioner: config_topic[:partitioner] || Klife.Producer.DefaultPartitioner
      }

      case :ets.lookup(table_name, topic.name) do
        [{_key, ^data}] -> :noop
        _ -> :ets.insert(table_name, {topic.name, data})
      end
    end

    :ok
  end

  defp topics_partitions_metadata_table(cluster_name),
    do: :"topics_partitions_metadata.#{cluster_name}"

  defp partitioner_metadata_table(cluster_name),
    do: :"partitioner_metadata.#{cluster_name}"
end
