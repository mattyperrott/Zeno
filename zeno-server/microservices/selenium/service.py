
from fastapi import FastAPI
from selenium import webdriver
from selenium.webdriver.chrome.options import Options

app = FastAPI()

@app.get("/html")
def html(url: str):
    opts = Options()
    opts.add_argument('--headless')
    driver = webdriver.Chrome(options=opts)
    driver.get(url)
    html = driver.page_source
    driver.quit()
    return {"html": html[:2048]}
