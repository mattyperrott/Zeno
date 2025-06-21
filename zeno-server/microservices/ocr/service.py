
from fastapi import FastAPI, UploadFile, File
from PIL import Image
import pytesseract, io

app = FastAPI()

@app.post("/ocr")
async def ocr(file: UploadFile = File(...)):
    img = Image.open(io.BytesIO(await file.read()))
    return {"text": pytesseract.image_to_string(img)}
