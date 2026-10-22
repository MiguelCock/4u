from pydantic import BaseModel


class ProfileCreate(BaseModel):
    # Optional: create_profile always forces it to the verified caller, and
    # AuthGate's missing-profile self-heal sends no id at all. Required, it
    # made that self-heal fail with a 422.
    id: str | None = None
    place_id: str | None = None
    role_id: int | None = None
    full_name: str | None = None
    avatar_url: str | None = None
    phone: str | None = None
    preferences: dict = {"verbosity": "medium", "feedback_type": "voice"}
    is_active: bool = True


class ProfileUpdate(BaseModel):
    place_id: str | None = None
    role_id: int | None = None
    full_name: str | None = None
    avatar_url: str | None = None
    phone: str | None = None
    preferences: dict | None = None
    is_active: bool | None = None


class ProfileResponse(ProfileCreate):
    created_at: str
    updated_at: str


class OrphanedUser(BaseModel):
    id: str
    email: str | None = None
    created_at: str | None = None


class RoleResponse(BaseModel):
    id: int
    name: str
