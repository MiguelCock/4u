from unittest.mock import AsyncMock, patch

import httpx
import pytest

from app import model_machines
from app.main import _search_similar
from app.model_machines import ModelMachines, parse_urls

A = "http://a"
B = "http://b"
MAIN = "http://ai-training:80"


def _answer(status=200, matches=()):
    request = httpx.Request("POST", "http://x/search_similar")
    return httpx.Response(
        status,
        json={"matches": list(matches), "timing_ms": {"embed": 400, "qdrant": 100}},
        request=request,
    )


class Machines:
    """A fake network: what each machine answers, and who was called."""

    def __init__(self, **by_host):
        self.by_host = by_host
        self.calls = []

    async def post(self, url, **_kwargs):
        host = url.removesuffix("/search_similar").removeprefix("http://")
        self.calls.append(host)
        result = self.by_host[host.split(":")[0].replace("-", "_")]
        if isinstance(result, Exception):
            raise result
        return result


async def _search(network, machines):
    client = AsyncMock()
    client.post = network.post
    client.__aenter__.return_value = client
    client.__aexit__.return_value = None
    timing = {}
    with (
        patch("app.main.httpx.AsyncClient", return_value=client),
        patch("app.main._machines", machines),
    ):
        matches = await _search_similar(b"x", "f.jpg", 6.2, -75.5, timing=timing)
    return matches, timing


def test_machines_take_turns():
    machines = ModelMachines([A, B])
    assert machines.order() == [A, B]
    assert machines.order() == [B, A]
    assert machines.order() == [A, B]


def test_no_machines_means_nothing_to_try():
    assert ModelMachines([]).order() == []


def test_a_skipped_machine_comes_back(monkeypatch):
    machines = ModelMachines([A, B])
    now = 1000.0
    monkeypatch.setattr(model_machines.time, "monotonic", lambda: now)
    machines.skip(A, "refused")
    assert machines.order() == [B]
    now += model_machines.SKIP_SECONDS
    assert sorted(machines.order()) == [A, B]


def test_parse_urls():
    assert parse_urls(None) == []
    assert parse_urls("") == []
    assert parse_urls("http://a/, http://b") == [A, B]


@pytest.mark.asyncio
async def test_a_model_machine_answers_before_the_main_one():
    network = Machines(a=_answer(matches=[{"id": 1}]), ai_training=_answer())
    matches, timing = await _search(network, ModelMachines([A]))
    assert matches == [{"id": 1}]
    assert network.calls == ["a"]
    assert timing["embed"] == 400
    assert "busy" not in timing


@pytest.mark.asyncio
async def test_with_no_model_machines_only_the_main_one_is_asked():
    network = Machines(ai_training=_answer(matches=[{"id": 2}]))
    matches, _ = await _search(network, ModelMachines([]))
    assert matches == [{"id": 2}]
    assert network.calls == ["ai-training:80"]


@pytest.mark.asyncio
async def test_a_busy_machine_passes_the_photo_on():
    network = Machines(a=_answer(503), b=_answer(matches=[{"id": 3}]))
    matches, timing = await _search(network, ModelMachines([A, B]))
    assert matches == [{"id": 3}]
    assert network.calls == ["a", "b"]
    assert "busy" not in timing


@pytest.mark.asyncio
async def test_all_busy_ends_at_the_main_machine_and_says_busy():
    network = Machines(a=_answer(503), b=_answer(503), ai_training=_answer(503))
    matches, timing = await _search(network, ModelMachines([A, B]))
    assert matches == []
    assert network.calls == ["a", "b", "ai-training:80"]
    assert timing["busy"] is True


@pytest.mark.asyncio
async def test_the_main_machine_takes_the_overflow():
    network = Machines(a=_answer(503), ai_training=_answer(matches=[{"id": 4}]))
    matches, timing = await _search(network, ModelMachines([A]))
    assert matches == [{"id": 4}]
    assert "busy" not in timing


@pytest.mark.parametrize(
    "failure",
    [httpx.ConnectError("refused"), httpx.ConnectTimeout("off"), _answer(500)],
)
@pytest.mark.asyncio
async def test_a_failed_machine_is_skipped_for_the_next_photos(failure):
    network = Machines(a=failure, ai_training=_answer(matches=[{"id": 5}]))
    machines = ModelMachines([A])
    matches, timing = await _search(network, machines)
    assert matches == [{"id": 5}]
    assert "busy" not in timing

    await _search(network, machines)
    assert network.calls == ["a", "ai-training:80", "ai-training:80"]


@pytest.mark.asyncio
async def test_a_timeout_isnt_sent_anywhere_else():
    network = Machines(a=httpx.ReadTimeout("slow"), ai_training=_answer())
    matches, timing = await _search(network, ModelMachines([A]))
    assert matches == []
    assert network.calls == ["a"]
    assert timing["busy"] is True


@pytest.mark.asyncio
async def test_no_time_left_ends_the_search(monkeypatch):
    monkeypatch.setattr("app.main._SEARCH_TOTAL_SECONDS", 0)
    network = Machines(a=_answer(), ai_training=_answer())
    matches, timing = await _search(network, ModelMachines([A]))
    assert matches == []
    assert network.calls == []
    assert timing["busy"] is True
