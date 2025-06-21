
from celery import Celery

app = Celery('zeno', broker="redis://zeno-redis:6379/0", backend="redis://zeno-redis:6379/0")

@app.task
def ping():
    return "pong"
