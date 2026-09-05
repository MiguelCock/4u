import packages.qdrant
import packages.supabase


def test_supabase_module_imports():
    assert hasattr(packages.supabase, "SupaBase")


def test_qdrant_module_imports():
    assert hasattr(packages.qdrant, "SupaBase")
