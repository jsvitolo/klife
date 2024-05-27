defmodule Klife.ProducerTest do
  use ExUnit.Case

  alias Klife.Record

  alias Klife.Producer.Controller, as: ProdController
  alias Klife.TestUtils

  defp assert_offset(expected_record, cluster, offset) do
    stored_record =
      TestUtils.get_record_by_offset(
        cluster,
        expected_record.topic,
        expected_record.partition,
        offset
      )

    Enum.each(Map.from_struct(expected_record), fn {k, v} ->
      if k in [:value, :key, :headers] do
        assert v == Map.get(stored_record, k)
      end
    end)
  end

  defp assert_resp_record(expected_record, response_record) do
    Enum.each(Map.from_struct(expected_record), fn {k, v} ->
      if v != nil do
        assert v == Map.get(response_record, k)
      end
    end)
  end

  defp wait_batch_cycle(cluster, topic, partition) do
    rec = %Record{
      value: "wait_cycle",
      key: "wait_cycle",
      headers: [],
      topic: topic,
      partition: partition
    }

    {:ok, _} = Klife.produce(rec, cluster: cluster)
  end

  defp now_unix(), do: DateTime.utc_now() |> DateTime.to_unix()

  test "produce message sync no batching" do
    record = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 1
    }

    cluster = :my_test_cluster_1

    assert {:ok, %Record{offset: offset} = resp_rec} = Klife.produce(record)

    assert_resp_record(record, resp_rec)
    assert_offset(record, cluster, offset)
    record_batch = TestUtils.get_record_batch_by_offset(cluster, record.topic, 1, offset)
    assert length(record_batch) == 1
  end

  test "produce message sync using non default producer" do
    record = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 1
    }

    cluster = :my_test_cluster_1

    assert {:ok, %Record{} = rec} =
             Klife.produce(record, producer: :benchmark_producer)

    assert_offset(record, cluster, rec.offset)

    record_batch =
      TestUtils.get_record_batch_by_offset(cluster, record.topic, record.partition, rec.offset)

    assert length(record_batch) == 1
  end

  test "produce message sync with batching" do
    cluster = :my_test_cluster_1
    topic = "test_batch_topic"

    wait_batch_cycle(cluster, topic, 1)

    rec_1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    task_1 =
      Task.async(fn ->
        Klife.produce(rec_1)
      end)

    rec_2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    Process.sleep(5)

    task_2 =
      Task.async(fn ->
        Klife.produce(rec_2)
      end)

    rec_3 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    Process.sleep(5)

    task_3 =
      Task.async(fn ->
        Klife.produce(rec_3)
      end)

    assert [
             {:ok, %Record{} = resp_rec1},
             {:ok, %Record{} = resp_rec2},
             {:ok, %Record{} = resp_rec3}
           ] =
             Task.await_many([task_1, task_2, task_3], 2_000)

    assert resp_rec2.offset - resp_rec1.offset == 1
    assert resp_rec3.offset - resp_rec2.offset == 1

    assert_offset(rec_1, cluster, resp_rec1.offset)
    assert_offset(rec_2, cluster, resp_rec2.offset)
    assert_offset(rec_3, cluster, resp_rec3.offset)

    batch_1 = TestUtils.get_record_batch_by_offset(cluster, topic, 1, resp_rec1.offset)
    batch_2 = TestUtils.get_record_batch_by_offset(cluster, topic, 1, resp_rec2.offset)
    batch_3 = TestUtils.get_record_batch_by_offset(cluster, topic, 1, resp_rec3.offset)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3
  end

  test "produce message sync with batching and compression" do
    cluster = :my_test_cluster_1
    topic = "test_compression_topic"
    partition = 1

    wait_batch_cycle(cluster, topic, partition)

    rec_1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: partition
    }

    task_1 =
      Task.async(fn ->
        Klife.produce(rec_1)
      end)

    rec_2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: partition
    }

    Process.sleep(5)

    task_2 =
      Task.async(fn ->
        Klife.produce(rec_2)
      end)

    rec_3 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: partition
    }

    Process.sleep(5)

    task_3 =
      Task.async(fn ->
        Klife.produce(rec_3)
      end)

    assert [
             {:ok, %Record{} = resp_rec1},
             {:ok, %Record{} = resp_rec2},
             {:ok, %Record{} = resp_rec3}
           ] =
             Task.await_many([task_1, task_2, task_3], 2_000)

    assert resp_rec2.offset - resp_rec1.offset == 1
    assert resp_rec3.offset - resp_rec2.offset == 1

    assert_offset(rec_1, cluster, resp_rec1.offset)
    assert_offset(rec_2, cluster, resp_rec2.offset)
    assert_offset(rec_3, cluster, resp_rec3.offset)

    batch_1 = TestUtils.get_record_batch_by_offset(cluster, topic, partition, resp_rec1.offset)
    batch_2 = TestUtils.get_record_batch_by_offset(cluster, topic, partition, resp_rec2.offset)
    batch_3 = TestUtils.get_record_batch_by_offset(cluster, topic, partition, resp_rec3.offset)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3

    assert [%{attributes: attr}] =
             TestUtils.get_partition_resp_records_by_offset(cluster, topic, 1, resp_rec1.offset)

    assert :snappy = KlifeProtocol.RecordBatch.decode_attributes(attr).compression
  end

  test "is able to recover from cluster changes" do
    cluster = :my_test_cluster_1
    topic = "test_no_batch_topic"

    record = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    assert {:ok, %Record{} = resp_rec} = Klife.produce(record)

    assert_offset(record, cluster, resp_rec.offset)

    %{broker_id: old_broker_id} = ProdController.get_topics_partitions_metadata(cluster, topic, 1)

    {:ok, service_name} = TestUtils.stop_broker(cluster, old_broker_id)

    Process.sleep(50)

    %{broker_id: new_broker_id} = ProdController.get_topics_partitions_metadata(cluster, topic, 1)

    assert new_broker_id != old_broker_id

    record = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    assert {:ok, %Record{} = resp_rec} = Klife.produce(record)

    assert_offset(record, cluster, resp_rec.offset)

    {:ok, _} = TestUtils.start_broker(service_name, cluster)
  end

  test "produce batch message sync no batching" do
    rec1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 1
    }

    rec2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 1
    }

    rec3 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 1
    }

    cluster = :my_test_cluster_1

    assert [
             {:ok, %Record{offset: offset1}},
             {:ok, %Record{offset: offset2}},
             {:ok, %Record{offset: offset3}}
           ] = Klife.produce([rec1, rec2, rec3])

    assert_offset(rec1, cluster, offset1)
    assert_offset(rec2, cluster, offset2)
    assert_offset(rec3, cluster, offset3)

    record_batch = TestUtils.get_record_batch_by_offset(cluster, rec1.topic, 1, offset1)
    assert length(record_batch) == 3
  end

  test "produce batch message sync no batching - multi partition/topic" do
    rec1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 0
    }

    rec2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 1
    }

    rec3 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic",
      partition: 2
    }

    rec4 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic_2",
      partition: 0
    }

    rec5 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic_2",
      partition: 0
    }

    cluster = :my_test_cluster_1

    assert [
             {:ok, %Record{offset: offset1}},
             {:ok, %Record{offset: offset2}},
             {:ok, %Record{offset: offset3}},
             {:ok, %Record{offset: offset4}},
             {:ok, %Record{offset: offset5}}
           ] = Klife.produce([rec1, rec2, rec3, rec4, rec5])

    assert_offset(rec1, cluster, offset1)
    assert_offset(rec2, cluster, offset2)
    assert_offset(rec3, cluster, offset3)
    assert_offset(rec4, cluster, offset4)
    assert_offset(rec5, cluster, offset5)

    record_batch =
      TestUtils.get_record_batch_by_offset(cluster, rec1.topic, rec1.partition, offset1)

    assert length(record_batch) == 1

    record_batch =
      TestUtils.get_record_batch_by_offset(cluster, rec2.topic, rec2.partition, offset2)

    assert length(record_batch) == 1

    record_batch =
      TestUtils.get_record_batch_by_offset(cluster, rec3.topic, rec3.partition, offset3)

    assert length(record_batch) == 1

    record_batch =
      TestUtils.get_record_batch_by_offset(cluster, rec4.topic, rec4.partition, offset4)

    assert length(record_batch) == 2
  end

  test "produce batch message sync with batching" do
    cluster = :my_test_cluster_1
    topic = "test_batch_topic"

    wait_batch_cycle(cluster, topic, 1)

    rec1_1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    rec1_2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 2
    }

    task_1 =
      Task.async(fn ->
        Klife.produce([rec1_1, rec1_2])
      end)

    rec2_1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    rec2_2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 2
    }

    Process.sleep(5)

    task_2 =
      Task.async(fn ->
        Klife.produce([rec2_1, rec2_2])
      end)

    rec3_1 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 1
    }

    rec3_2 = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: topic,
      partition: 2
    }

    Process.sleep(5)

    task_3 =
      Task.async(fn ->
        Klife.produce([rec3_1, rec3_2])
      end)

    assert [
             [{:ok, %Record{offset: offset1_1}}, {:ok, %Record{offset: offset1_2}}],
             [{:ok, %Record{offset: offset2_1}}, {:ok, %Record{offset: offset2_2}}],
             [{:ok, %Record{offset: offset3_1}}, {:ok, %Record{offset: offset3_2}}]
           ] =
             Task.await_many([task_1, task_2, task_3], 2_000)

    assert offset2_1 - offset1_1 == 1
    assert offset3_1 - offset2_1 == 1

    assert offset2_2 - offset1_2 == 1
    assert offset3_2 - offset2_2 == 1

    assert_offset(rec1_1, cluster, offset1_1)
    assert_offset(rec1_2, cluster, offset1_2)
    assert_offset(rec2_1, cluster, offset2_1)
    assert_offset(rec2_2, cluster, offset2_2)
    assert_offset(rec3_1, cluster, offset3_1)
    assert_offset(rec3_2, cluster, offset3_2)

    batch_1 = TestUtils.get_record_batch_by_offset(cluster, topic, 1, offset1_1)
    batch_2 = TestUtils.get_record_batch_by_offset(cluster, topic, 1, offset2_1)
    batch_3 = TestUtils.get_record_batch_by_offset(cluster, topic, 1, offset3_1)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3

    batch_1 = TestUtils.get_record_batch_by_offset(cluster, topic, 2, offset1_2)
    batch_2 = TestUtils.get_record_batch_by_offset(cluster, topic, 2, offset2_2)
    batch_3 = TestUtils.get_record_batch_by_offset(cluster, topic, 2, offset3_2)

    assert length(batch_1) == 3
    assert batch_1 == batch_2 and batch_2 == batch_3
  end

  test "produce record using default partitioner" do
    record = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic"
    }

    cluster = :my_test_cluster_1

    assert {:ok,
            %Record{
              offset: offset,
              partition: partition,
              topic: topic
            } = resp_rec} = Klife.produce(record)

    assert_resp_record(record, resp_rec)
    assert_offset(resp_rec, cluster, offset)

    record_batch = TestUtils.get_record_batch_by_offset(cluster, topic, partition, offset)
    assert length(record_batch) == 1
  end

  test "produce record using custom partitioner on config" do
    record = %Record{
      value: :rand.bytes(10),
      key: "3",
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic_2"
    }

    cluster = :my_test_cluster_1

    assert {:ok,
            %Record{
              offset: offset,
              partition: 3,
              topic: topic
            } = resp_rec} = Klife.produce(record)

    assert_resp_record(record, resp_rec)
    assert_offset(resp_rec, cluster, offset)

    record_batch = TestUtils.get_record_batch_by_offset(cluster, topic, 3, offset)
    assert length(record_batch) == 1
  end

  test "produce record using custom partitioner on opts" do
    record = %Record{
      value: :rand.bytes(10),
      key: "4",
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_no_batch_topic"
    }

    cluster = :my_test_cluster_1

    assert {:ok,
            %Record{
              offset: offset,
              partition: 4,
              topic: topic
            } = resp_rec} = Klife.produce(record, partitioner: Klife.TestCustomPartitioner)

    assert_resp_record(record, resp_rec)
    assert_offset(resp_rec, cluster, offset)

    record_batch = TestUtils.get_record_batch_by_offset(cluster, topic, 4, offset)
    assert length(record_batch) == 1
  end

  test "produce message async no batching" do
    rec = %Record{
      value: :rand.bytes(10),
      key: :rand.bytes(10),
      headers: [%{key: :rand.bytes(10), value: :rand.bytes(10)}],
      topic: "test_async_topic",
      partition: 1
    }

    cluster = :my_test_cluster_1

    base_ts = now_unix()
    assert :ok = Klife.produce(rec, async: true)

    Process.sleep(10)

    offset = TestUtils.get_latest_offset(cluster, rec.topic, rec.partition, base_ts)

    assert_offset(rec, cluster, offset)
    record_batch = TestUtils.get_record_batch_by_offset(cluster, rec.topic, 1, offset)
    assert length(record_batch) == 1
  end
end
