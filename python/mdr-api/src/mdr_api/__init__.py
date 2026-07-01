from typing import Literal
from fastapi import FastAPI
from pydantic import BaseModel


class HealthResponse(BaseModel):
    status: Literal["ok"]


def create_app() -> FastAPI:
    app = FastAPI()

    @app.get("/health")
    def health() -> HealthResponse:
        return HealthResponse(status="ok")

    return app
