defmodule FekFetcher do
  defmodule FekSearchResult do
    @enforce_keys [
      :document_number,
      :id,
      :issue_date,
      :issue_group_id,
      :primary_label,
      :publication_date
    ]
    defstruct [
      :document_number,
      :id,
      :issue_date,
      :issue_group_id,
      :primary_label,
      :publication_date
    ]

    @type t :: %__MODULE__{
            document_number: String.t(),
            id: String.t(),
            issue_date: String.t(),
            issue_group_id: String.t(),
            primary_label: String.t(),
            publication_date: String.t()
          }

    @spec from_search_result(map()) :: {:ok, t()} | {:error, String.t()}
    def from_search_result(data) do
      with {:ok, document_number} <- Map.fetch(data, "search_DocumentNumber"),
           {:ok, id} <- Map.fetch(data, "search_ID"),
           {:ok, issue_date} <- Map.fetch(data, "search_IssueDate"),
           {:ok, issue_group_id} <- Map.fetch(data, "search_IssueGroupID"),
           {:ok, primary_label} <- Map.fetch(data, "search_PrimaryLabel"),
           {:ok, publication_date} <- Map.fetch(data, "search_PublicationDate") do
        {:ok,
         %__MODULE__{
           document_number: document_number,
           id: id,
           issue_date: issue_date,
           issue_group_id: issue_group_id,
           primary_label: primary_label,
           publication_date: publication_date
         }}
      else
        :error -> {:error, "Missing required fields in search result"}
      end
    end

    def issue_year(%__MODULE__{issue_date: issue_date}) do
      [date, _time] = issue_date |> String.split(" ")
      [_month, _day, issue_year] = date |> String.split("/")

      issue_year
    end
  end

  @base_url "https://searchetv99.azurewebsites.net/api/"
  @pdf_base_url "https://ia37rg02wpsa01.blob.core.windows.net/fek/"

  defp get(url) do
    case Req.get(url) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Request failed with status #{status}"}

      {:error, reason} ->
        {:error, "Request failed: #{reason}"}
    end
  end

  defp post(url, data) do
    case Req.post(url, json: data) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Request failed with status #{status}"}

      {:error, reason} ->
        {:error, "Request failed: #{reason}"}
    end
  end

  defp pdf_url(%FekSearchResult{} = fek) do
    document_number = fek.document_number |> String.pad_leading(5, "0")
    issue_group_id = fek.issue_group_id |> String.pad_leading(2, "0")
    issue_year = FekSearchResult.issue_year(fek)

    filename = "#{issue_year}#{issue_group_id}#{document_number}"

    "#{@pdf_base_url}#{issue_group_id}/#{issue_year}/#{filename}.pdf"
  end


  defp base_fek_path(%FekSearchResult{} = fek, base_path) do
    year = FekSearchResult.issue_year(fek)
    primary_label = fek.primary_label |> String.replace("/", "_")

    Path.join(base_path, year) |> Path.join(primary_label)
  end

  defp spawn_tasks_to_get_json_metadata(%FekSearchResult{} = fek, dst) do
    async_process = fn filename, url_path ->
      Task.async(fn ->
        file_path = Path.join(dst, filename)
        with {:ok, %{"data" => data}} <- get(@base_url <> url_path) do
          File.write!(file_path, data)
        end
      end)
    end

    [
      %{filename: "metadata.json", path: "/documententitybyid/#{fek.id}"},
      %{filename: "timeline.json", path: "/timeline/#{fek.id}/0"},
      %{filename: "named_entity.json", path: "/namedentity/#{fek.id}"},
      %{filename: "tags.json", path: "/tagsbydocumententity/#{fek.id}"}
    ]
    |> Enum.map(&async_process.(&1.filename, &1.path))
  end

  defp get_pdf(%FekSearchResult{} = fek, dst) do
    pdf_url = pdf_url(fek)

    with {:ok, pdf_data} <- get(pdf_url) do
      file_path = Path.join(dst, "#{fek.document_number}.pdf")
      File.write!(file_path, pdf_data)
      {:ok, file_path}
    else
      {:error, reason} ->
        {:error, "Failed to download PDF: #{reason}"}
    end
  end

  def process_fek_result(%FekSearchResult{} = fek, dst) do
    fek_path = base_fek_path(fek, dst)
    File.mkdir_p!(fek_path)

    tasks = spawn_tasks_to_get_json_metadata(fek, fek_path)
    tasks = tasks ++ [Task.async(fn -> get_pdf(fek, fek_path) end)]
    Task.await_many(tasks, :infinity)

    {:ok, fek_path}
  end


  def search_feks(years, issues) do
    data = %{
      "selectYear" => years,
      "selectIssue" => issues
    }

    with {:ok, %{"data" => data}} <- post(@base_url <> "simplesearch", data),
         {:ok, parsed} <- JSON.decode(data) do
      feks =
        Enum.map(parsed, fn item ->
          case FekSearchResult.from_search_result(item) do
            {:ok, fek} -> fek
            {:error, reason} -> {:error, reason}
          end
        end)
      Enum.filter(feks, fn
        {:error, _} -> false
        _ -> true
      end)

      {:ok, feks}
    else
      {:error, reason} -> {:error, "Failed to fetch fek IDs: #{reason}"}
    end
  end
end
