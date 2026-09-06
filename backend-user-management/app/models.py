from pydantic import BaseModel


class ProfileCreate(BaseModel):
    id: str
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


class RoleResponse(BaseModel):
    id: int
    name: str
