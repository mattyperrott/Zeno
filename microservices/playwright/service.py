
from fastapi import FastAPI
from playwright.sync_api import sync_playwright

app = FastAPI()

@app.get("/title")
def title(url: str):
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()
        page.goto(url, timeout=60000)
        t = page.title()
        browser.close()
    return {"title": t}
