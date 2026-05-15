from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List
import httpx
import os
from dotenv import load_dotenv

load_dotenv()

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

GROQ_API_KEY = os.getenv("GROQ_API_KEY")
GROQ_URL = "https://api.groq.com/openai/v1/chat/completions"
MODEL = "llama-3.3-70b-versatile"

class InsightRequest(BaseModel):
    prompt: str

class ChatMessage(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    system_prompt: str
    history: List[ChatMessage]

async def call_groq(messages: list, max_tokens: int = 400) -> str:
    try:
        async with httpx.AsyncClient(timeout=30) as client:
            response = await client.post(
                GROQ_URL,
                headers={
                    "Authorization": f"Bearer {GROQ_API_KEY}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": MODEL,
                    "messages": messages,
                    "max_tokens": max_tokens,
                    "temperature": 0.7,
                },
            )
            response.raise_for_status()
            data = response.json()
            return data["choices"][0]["message"]["content"]
    except Exception as e:
        return f"Error: {str(e)}"

@app.get("/")
def root():
    return {"status": "Thrive API running "}

@app.post("/insight")
async def get_insight(req: InsightRequest):
    messages = [
        {
            "role": "system",
            "content": (
                "You are Thrive AI, a warm wellness coach. "
                "Reply with ONLY 2 sentences max. "
                "No bullet points, no greeting, no sign-off."
            ),
        },
        {"role": "user", "content": req.prompt},
    ]
    result = await call_groq(messages, max_tokens=80)
    return {"result": result}

@app.post("/chat")
async def chat(req: ChatRequest):
    messages = [{"role": "system", "content": req.system_prompt}]
    for msg in req.history:
        messages.append({"role": msg.role, "content": msg.content})
    reply = await call_groq(messages, max_tokens=300)
    return {"reply": reply}

# Add this new endpoint specifically for the home page
@app.get("/daily-insight")
async def get_daily_insight():
    messages = [
        {
            "role": "system",
            "content": (
                "You are Thrive AI, a warm wellness coach. "
                "Reply with ONLY 2 sentences max. "
                "No bullet points, no greeting, no sign-off."
            ),
        },
        {
            "role": "user",
            "content": (
                "Give me a short, motivating wellness insight for today "
                "focused on mental clarity and energy."
            ),
        },
    ]
    result = await call_groq(messages, max_tokens=80)
    return {"result": result}