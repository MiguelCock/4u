"""Signing up and in, and who may do what (AuthGate, signup_screen, Users tab)."""

import httpx

import stack


def test_a_new_account_has_a_user_profile(user):
    with user.client() as api:
        profile = api.get(f"/user/profiles/{user.id}").json()
    assert profile["id"] == user.id
    assert profile["role_id"] == 1
    assert profile["is_active"] is True


def test_a_missing_profile_heals_on_sign_in():
    """AuthGate's self-heal: an auth account whose profile POST failed."""
    email = f"{stack.unique('e2e')}@example.com"
    password = stack.unique("pw") + "Aa1!"
    body = httpx.post(
        f"{stack.SUPABASE}/auth/v1/signup",
        json={"email": email, "password": password},
        headers={"apikey": stack.PUBLISHABLE_KEY},
        timeout=30,
    ).json()
    account = stack.Account(email, password, body["user"]["id"], body["access_token"])
    with account.client() as api:
        assert api.get(f"/user/profiles/{account.id}").status_code == 404
        assert api.post("/user/profiles", json={}).status_code < 300
        assert api.get(f"/user/profiles/{account.id}").json()["role_id"] == 1


def test_a_user_cant_make_themselves_admin(user):
    with user.client() as api:
        api.patch(f"/user/profiles/{user.id}", json={"role_id": 2})
        assert api.get(f"/user/profiles/{user.id}").json()["role_id"] == 1


def test_admin_only_endpoints_refuse_users(user):
    with user.client() as api:
        assert api.get("/user/profiles").status_code == 403
        assert api.post("/map/places", json={}).status_code in (403, 422)
        assert (
            api.get(
                "/map/changes", params={"since": "2026-01-01T00:00:00Z"}
            ).status_code
            == 403
        )


def test_an_admin_can_list_every_profile(admin, user):
    with admin.client() as api:
        ids = {p["id"] for p in api.get("/user/profiles").json()}
        assert {admin.id, user.id} <= ids


def test_no_token_is_refused():
    with httpx.Client(base_url=stack.GATEWAY, timeout=30) as api:
        assert api.get("/map/anchor-points").status_code == 401
        # Health checks and the version policy need no token.
        assert api.get("/user/app-version").status_code == 200


def test_preferences_are_saved(user):
    with user.client() as api:
        api.patch(
            f"/user/profiles/{user.id}",
            json={"preferences": {"language": "es", "voice_guidance": True}},
        ).raise_for_status()
        preferences = api.get(f"/user/profiles/{user.id}").json()["preferences"]
    assert preferences["language"] == "es"
