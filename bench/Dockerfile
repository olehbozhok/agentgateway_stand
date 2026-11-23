FROM python:3.12-slim

RUN pip install --no-cache-dir "httpx==0.28.1" "numpy==2.2.6" "scipy==1.15.3"

WORKDIR /bench
COPY bench.py .

USER 1000
ENTRYPOINT ["python", "bench.py"]
