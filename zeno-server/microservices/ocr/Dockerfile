
FROM python:3.11-slim
RUN apt-get update && apt-get install -y tesseract-ocr && rm -rf /var/lib/apt/lists/*
WORKDIR /svc
RUN pip install fastapi uvicorn pytesseract pillow
COPY service.py .
CMD ["uvicorn","service:app","--host","0.0.0.0","--port","9001"]
