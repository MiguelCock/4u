"""Point names don't repeat their building: "Entrada sur bloque 20" in Bloque 20
is just "Entrada sur". The app shows the building next to the name, and voice
search counts the building's words, so "entrada sur bloque 20" still finds it.
"""

import re
import unicodedata

# In a building's name, but saying nothing about which building.
_GENERIC_WORDS = {"edificio", "bloque", "building", "block", "universidad"}

# What can be left before the building's name once it's gone.
_CONNECTORS = {"de", "del", "en"}

# The name is what the point is about, not where it is: "Escaleras hacia
# Biblioteca", "Frente al Saman".
_RELATION_WORDS = {
    "a",
    "al",
    "con",
    "cerca",
    "desde",
    "el",
    "frente",
    "hacia",
    "hasta",
    "junto",
    "la",
    "por",
    "y",
}

# A shorter form of a building's name must be this long, so that the M of
# "Edificio M" never matches a word on its own.
_MIN_SHORT_FORM_LETTERS = 4


def _normalize(word: str) -> str:
    plain = unicodedata.normalize("NFD", word.lower())
    plain = "".join(c for c in plain if unicodedata.category(c) != "Mn")
    return re.sub(r"[^a-z0-9]", "", plain)


def _words(text: str) -> list[str]:
    return [w for w in map(_normalize, text.split()) if w]


def _building_forms(building_name: str, place_name: str | None) -> list[list[str]]:
    """Ways a point's name may spell its building, longest first: the whole
    name, each part of "Edificio N - Ingenierías", and each of those without
    generic or campus words."""
    parts = [building_name, *re.split(r"\s[-–—]\s|\(|\)", building_name)]
    campus = set(_words(place_name or ""))
    forms: list[list[str]] = []
    for part in parts:
        words = _words(part)
        if words and words not in forms:
            forms.append(words)
        short = [w for w in words if w not in _GENERIC_WORDS and w not in campus]
        if len("".join(short)) >= _MIN_SHORT_FORM_LETTERS and short not in forms:
            forms.append(short)
    return sorted(forms, key=len, reverse=True)


def name_without_building(
    description: str, building_name: str, place_name: str | None = None
) -> str:
    """description without its building's name at the end, as whole words. A
    name that's only the building, or about it, stays as it is."""
    original = description.split()
    words = [_normalize(w) for w in original]
    for form in _building_forms(building_name, place_name):
        if len(form) >= len(words) or words[-len(form) :] != form:
            continue
        keep = len(words) - len(form)
        # "Baño Edificio Bienestar" with the form "bienestar".
        while keep > 0 and words[keep - 1] in _GENERIC_WORDS:
            keep -= 1
        if keep > 0 and words[keep - 1] in _RELATION_WORDS:
            return description
        while keep > 0 and words[keep - 1] in _CONNECTORS:
            keep -= 1
        if keep == 0:
            return description
        return " ".join(original[:keep]).rstrip(" -–—,")
    return description
