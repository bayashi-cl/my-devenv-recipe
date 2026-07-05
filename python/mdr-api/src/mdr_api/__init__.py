from typing import Literal
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # 対応するフロントのオリジン。デフォルト無し=未設定なら起動時に ValidationError。
    frontend_origin: str


class HealthResponse(BaseModel):
    status: Literal["ok"]


def create_app() -> FastAPI:
    settings = Settings()  # FRONTEND_ORIGIN 未設定なら ValidationError で起動失敗

    app = FastAPI()

    # 混線防止: 対応するフロントのオリジンのみ許可する
    app.add_middleware(
        CORSMiddleware,
        allow_origins=[settings.frontend_origin],
        allow_methods=["GET"],
        allow_headers=["*"],
    )

    @app.get("/health")
    def health() -> HealthResponse:
        return HealthResponse(status="ok")

    return app
