from dataclasses import dataclass
@dataclass(frozen=True, slots=True)
class Client:
    base_url: str
    bearer_token: str | None = None
    async def health(self) -> bool:
        return bool(self.base_url)
