defmodule Klife.Connection.MessageVersions do
  alias KlifeProtocol.Messages, as: M

  def get(cluster_name, mod), do: :persistent_term.get({:api_version, mod, cluster_name})

  def setup_versions(cluster_data, cluster_name),
    do: do_setup_versions(client_versions(), cluster_data, cluster_name)

  defp do_setup_versions([], _, _), do: :ok

  # TODO: Handle non required messages
  defp do_setup_versions([{mod, client_data} | rest], cluster_map, cluster_name) do
    api_key = apply(mod, :api_key, [])

    cluster_data = Map.get(cluster_map, api_key, :not_found)

    not_found_on_broker? = cluster_data == :not_found
    should_raise? = client_data.should_raise?

    if not_found_on_broker? and should_raise?,
      do: raise("Could not find required message #{inspect(mod)} for cluster #{cluster_name}")

    common_version = min(cluster_data.max, client_data.max)

    invalid_common_version? =
      common_version < cluster_data.min or common_version < client_data.min

    cond do
      not invalid_common_version? ->
        :ok = set_api_version(cluster_name, mod, common_version)
        do_setup_versions(rest, cluster_map, cluster_name)

      invalid_common_version? and should_raise? ->
        raise "Could not agree on API version for #{inspect(mod)} api_key #{api_key} for cluster #{cluster_name}. Cluster "

      true ->
        do_setup_versions(rest, cluster_map, cluster_name)
    end
  end

  defp client_versions do
    [
      {M.ApiVersions, %{min: 0, max: 0, should_raise?: true}},
      {M.CreateTopics, %{min: 0, max: 0, should_raise?: false}},
      {M.Metadata, %{min: 1, max: 1, should_raise?: true}},
      {M.Produce, %{min: 9, max: 9, should_raise?: false}},
      {M.InitProducerId, %{min: 0, max: 0, should_raise?: false}},
      {M.Fetch, %{min: 4, max: 4, should_raise?: true}},
      {M.ListOffsets, %{min: 2, max: 2, should_raise?: true}},
      {M.AddPartitionsToTxn, %{min: 4, max: 4, should_raise?: true}},
      {M.FindCoordinator, %{min: 4, max: 4, should_raise?: true}},
      {M.EndTxn, %{min: 3, max: 3, should_raise?: true}}
    ]
  end

  defp set_api_version(cluster_name, mod, version),
    do: :persistent_term.put({:api_version, mod, cluster_name}, version)
end
