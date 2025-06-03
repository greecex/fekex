dst = "data"
years = System.argv()
{:ok, results} = FekFetcher.search_feks(years, ["2"])

total = Enum.count(results)
File.mkdir_p!(dst)

results
|> Task.async_stream(fn fek -> FekFetcher.process_fek_result(fek, dst) end, timeout: :infinity, max_concurrency: 5)
|> Stream.with_index()
|> Enum.each(fn {_result, index} ->
  ProgressBar.render(index, total)
end)
