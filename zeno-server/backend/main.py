
import os, httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

app = FastAPI(title="Zeno Backend", version="0.1.0")
VLLM = os.getenv("VLLM_ENDPOINT", "http://zeno-inference:8000")

@app.get("/health")
def health():
    return {"status":"ok"}

@app.post("/v1/chat/completions")
async def completions(req: Request):
    payload = await req.json()
    async with httpx.AsyncClient(timeout=120) as client:
        res = await client.post(f"{VLLM}/v1/chat/completions", json=payload)
    return JSONResponse(content=res.json(), status_code=res.status_code)
