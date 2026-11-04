import pytest

from packages.geo import haversine_meters


def test_same_point_is_zero():
    assert haversine_meters(3.34, -76.53, 3.34, -76.53) == 0


def test_one_thousandth_of_a_degree_of_latitude_is_about_111_m():
    assert haversine_meters(3.340, -76.53, 3.341, -76.53) == pytest.approx(
        111.2, abs=0.2
    )


def test_is_symmetric():
    a = (6.2442, -75.5812)
    b = (6.2445, -75.5810)
    assert haversine_meters(*a, *b) == pytest.approx(haversine_meters(*b, *a))
