
FROM mcr.microsoft.com/playwright/python:v1.44.0-jammy
WORKDIR /svc
RUN pip install fastapi uvicorn
COPY service.py .
CMD ["uvicorn","service:app","--host","0.0.0.0","--port","9002"]
