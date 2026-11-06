import threading
import time

import pytest

from app.model_gate import ModelBusy, ModelGate


def test_a_search_runs_when_a_slot_is_free():
    gate = ModelGate(slots=1)
    with gate.search(wait_seconds=0):
        pass
    with gate.search(wait_seconds=0):
        pass


def test_a_search_is_refused_after_its_wait():
    gate = ModelGate(slots=1)
    with gate.search(wait_seconds=0):
        started = time.monotonic()
        with pytest.raises(ModelBusy), gate.search(wait_seconds=0.05):
            pass
        assert time.monotonic() - started < 1


def test_a_failed_model_call_frees_its_slot():
    gate = ModelGate(slots=1)
    with pytest.raises(ValueError), gate.search(wait_seconds=0):
        raise ValueError
    with gate.search(wait_seconds=0):
        pass


def test_a_search_takes_a_slot_that_frees_during_its_wait():
    gate = ModelGate(slots=1)
    entered = threading.Event()
    release = threading.Event()

    def hold():
        with gate.search(wait_seconds=0):
            entered.set()
            release.wait(5)

    thread = threading.Thread(target=hold)
    thread.start()
    entered.wait(5)
    threading.Timer(0.05, release.set).start()
    with gate.search(wait_seconds=5):
        pass
    thread.join()


def test_at_most_one_index_runs_however_many_slots_are_free():
    gate = ModelGate(slots=2)
    with gate.index(wait_seconds=0):
        with pytest.raises(ModelBusy), gate.index(wait_seconds=0):
            pass
        # The other slot stays open for users.
        with gate.search(wait_seconds=0):
            pass


def test_indexing_waits_while_a_users_photo_is_waiting():
    gate = ModelGate(slots=1)
    order = []
    holding = threading.Event()
    release = threading.Event()

    def hold():
        with gate.search(wait_seconds=0):
            holding.set()
            release.wait(5)

    def run(name, context):
        with context:
            order.append(name)

    holder = threading.Thread(target=hold)
    holder.start()
    holding.wait(5)

    index = threading.Thread(target=run, args=("index", gate.index(5)))
    index.start()
    time.sleep(0.05)
    search = threading.Thread(target=run, args=("search", gate.search(5)))
    search.start()
    time.sleep(0.05)
    release.set()

    for thread in (holder, index, search):
        thread.join(5)
    assert order == ["search", "index"]


def test_indexing_goes_ahead_when_the_waiting_photo_gives_up():
    gate = ModelGate(slots=2)
    with (
        gate.search(wait_seconds=0),
        gate.search(wait_seconds=0),
        pytest.raises(ModelBusy),
        gate.search(wait_seconds=0.01),
    ):
        pass
    with gate.index(wait_seconds=0):
        pass


def test_indexing_is_refused_after_its_wait():
    gate = ModelGate(slots=1)
    with (
        gate.search(wait_seconds=0),
        pytest.raises(ModelBusy),
        gate.index(wait_seconds=0.01),
    ):
        pass


def test_a_search_is_refused_at_once_when_too_many_are_waiting():
    gate = ModelGate(slots=1, max_waiting=1)
    release = threading.Event()
    entered = threading.Event()

    def hold():
        with gate.search(wait_seconds=0):
            entered.set()
            release.wait(5)

    def wait_in_line():
        with pytest.raises(ModelBusy), gate.search(wait_seconds=0.3):
            pass

    holder = threading.Thread(target=hold)
    holder.start()
    entered.wait(5)
    waiter = threading.Thread(target=wait_in_line)
    waiter.start()
    time.sleep(0.05)

    started = time.monotonic()
    with pytest.raises(ModelBusy), gate.search(wait_seconds=5):
        pass
    assert time.monotonic() - started < 1

    waiter.join(5)
    release.set()
    holder.join(5)
