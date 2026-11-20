FROM python:3.12-slim

RUN pip install --no-cache-dir "mcp==1.26.0"

WORKDIR /app
COPY server.py .

USER 1000
EXPOSE 8000
CMD ["python", "server.py"]
