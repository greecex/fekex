import asyncio
from contextlib import asynccontextmanager
import logging
from sys import argv
import aiohttp
import json
from pathlib import Path
from tqdm.asyncio import tqdm_asyncio

BASE_URL = "https://searchetv99.azurewebsites.net/api/"
PDF_BASE_URL = "https://ia37rg02wpsa01.blob.core.windows.net/fek/"

logger = logging.getLogger(__name__)
logger.setLevel("DEBUG")


@asynccontextmanager
async def get(session: aiohttp.ClientSession, url: str):
    async with session.get(url) as response:
        yield response


@asynccontextmanager
async def post(session: aiohttp.ClientSession, url: str, data: dict):
    logger.critical("POST request to %s", url)
    async with session.post(url, json=data) as response:
        logger.critical("POST request to %s, got response", url)
        yield response


async def fek_ids_per_year_and_issue(
    session: aiohttp.ClientSession, years: list[str], issues: list[str]
):
    data = {"selectYear": years, "selectIssue": issues}
    resp = await session.post(BASE_URL + "simplesearch", json=data)
    resp_data = await resp.json()

    return json.loads(resp_data["data"])


async def process_year(session: aiohttp.ClientSession, year: str, issues: list[str]):
    logger.critical("Processing year %s", year)
    feks = await fek_ids_per_year_and_issue(session, [year], issues)
    path = Path("data").joinpath(year)
    path.mkdir(parents=True, exist_ok=True)

    with open(path.joinpath("search_results.json"), "w") as feks_file:
        json.dump(feks, feks_file, indent=2, ensure_ascii=False)

    tasks = []
    for fek in feks:
        tasks.append(
            process_fek(
                session=session,
                output_dir=path,
                fek_id=fek["search_ID"],
                fek_name=fek["search_PrimaryLabel"].replace("/", "-"),
            )
        )

    await tqdm_asyncio.gather(
        *tasks,
        desc=f"Processing FEKs for {year}",
        position=0,
    )


async def get_and_parse(session: aiohttp.ClientSession, path: str) -> str:
    async with get(session, BASE_URL + path) as response:
        data = await response.json()

        return data["data"]


def pdf_path(metadata) -> str:
    m = metadata[0]
    document_number: str = m["documententitybyid_DocumentNumber"].zfill(5)
    issue_group_id: str = m["documententitybyid_IssueGroupID"].zfill(2)
    issue_date: str = m["documententitybyid_IssueDate"]  # '06/25/1992 00:00:00'
    issue_year = issue_date.split("/")[2].split(" ")[0]

    filename = f"{issue_year}{issue_group_id}{document_number}.pdf"

    return f"{issue_group_id}/{issue_year}/{filename}"


async def download_entity_and_pdf(
    session: aiohttp.ClientSession, local_dir: Path, fek_id: str
):
    try:
        if not local_dir.joinpath("metadata.json").exists():
            metadata = await get_and_parse(session, f"documententitybyid/{fek_id}")
            parsed_metadata = json.loads(metadata)

            with open(local_dir.joinpath("metadata.json"), "w") as metadata_file:
                metadata_file.write(metadata)
        else:
            with open(local_dir.joinpath("metadata.json"), "r") as metadata_file:
                parsed_metadata = json.load(metadata_file)

        if not local_dir.joinpath("document.pdf").exists():
            async with get(session, PDF_BASE_URL + pdf_path(parsed_metadata)) as resp:
                pdf_data = await resp.read()
                with open(local_dir.joinpath("document.pdf"), "wb") as pdf_file:
                    pdf_file.write(pdf_data)
    except Exception as e:
        print(f"Error downloading {fek_id}: {e}")


async def download_and_write_to_file(
    session: aiohttp.ClientSession, remote_path: str, filename: str
):
    try:
        if Path(filename).exists():
            return

        json_str = await get_and_parse(session, remote_path)

        with open(filename, "w") as file:
            file.write(json_str)
    except Exception as e:
        print(f"Error downloading {remote_path}: {e}")


async def download_tags(session: aiohttp.ClientSession):
    await download_and_write_to_file(
        session, remote_path="tags", filename="data/tags.json"
    )


async def process_fek(
    session: aiohttp.ClientSession, output_dir: Path, fek_id: str, fek_name: str
):
    local_dir = output_dir.joinpath(fek_name)
    local_dir.mkdir(parents=True, exist_ok=True)

    async with asyncio.TaskGroup() as tg:
        tg.create_task(download_entity_and_pdf(session, local_dir, fek_id))

        endpoints = [
            {"name": "timeline", "remote_path": f"/timeline/{fek_id}/0"},
            {"name": "named_entity", "remote_path": f"/namedentity/{fek_id}"},
            {
                "name": "tags_by_document",
                "remote_path": f"/tagsbydocumententity/{fek_id}",
            },
        ]

        for endpoint in endpoints:
            local_path = str(local_dir.joinpath(f"{endpoint['name']}.json"))
            tg.create_task(
                download_and_write_to_file(
                    session, remote_path=endpoint["remote_path"], filename=local_path
                )
            )


async def main():
    Path("data").mkdir(exist_ok=True)
    years = set(argv[1:])

    connector = aiohttp.TCPConnector(limit_per_host=30)

    async with aiohttp.ClientSession(connector=connector) as session:
        await download_tags(session)
        for year in years:
            await process_year(session, year, ["2"])


if __name__ == "__main__":
    logger.critical("Starting asyncio.run(main())")
    asyncio.run(main())
