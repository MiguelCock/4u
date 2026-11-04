import pytest

from app.names import name_without_building


@pytest.mark.parametrize(
    "description,building,place,expected",
    [
        ("Entrada sur bloque 20", "Bloque 20", "EAFIT", "Entrada sur"),
        ("Entrada baño bloque 13", "Bloque 13", "EAFIT", "Entrada baño"),
        ("Multimedios Edificio E", "Edificio E", "Icesi", "Multimedios"),
        ("entrada 2 edificio G", "Edificio G", "Icesi", "entrada 2"),
        # The short form of a long name, ignoring accents and case.
        (
            "Escaleras lado derecho BIBLIOTECA",
            "Edificio Biblioteca Universidad Icesi",
            "Icesi",
            "Escaleras lado derecho",
        ),
        ("entrada cafeteria central", "cafetería central", "Icesi", "entrada"),
        ("mesas de estudio caballerizas", "caballerizas", "Icesi", "mesas de estudio"),
        # One part of a name with a dash.
        (
            "Maquina para pagar Edificio N",
            "Edificio N - Ingenierías",
            "Icesi",
            "Maquina para pagar",
        ),
        # A generic word left over, and a connector.
        (
            "Baño Edificio Bienestar Universitario",
            "Bienestar Universitario - Edificio I",
            "Icesi",
            "Baño",
        ),
        ("Baño del bloque 20", "Bloque 20", "EAFIT", "Baño"),
    ],
)
def test_building_is_removed(description, building, place, expected):
    assert name_without_building(description, building, place) == expected


@pytest.mark.parametrize(
    "description,building",
    [
        # Glued to a word, or a word that only ends the same.
        ("Pasillo piso 3M", "Edificio M"),
        ("desarrollo comercial y marketing", "Edificio G"),
        # A single letter alone is never the building.
        ("Sala m", "Edificio M"),
        # Only the building.
        ("Edificio C", "Edificio C"),
        ("Biblioteca", "Edificio Biblioteca Universidad Icesi"),
        # Not at the end.
        ("Bloque 20 ala norte", "Bloque 20"),
        ("Puente Edificio B y C", "Edificio C"),
        # About the building, not just in it.
        ("Escaleras hacia Biblioteca", "Edificio Biblioteca Universidad Icesi"),
        ("frente al saman", "Saman"),
        # Another building.
        ("Entrada sur bloque 20", "Bloque 13"),
    ],
)
def test_name_stays(description, building):
    assert name_without_building(description, building, "Icesi") == description
