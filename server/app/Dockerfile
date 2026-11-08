FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 HT_DATA=/data
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd -u 10001 -M -d /srv ht && mkdir /data && chown ht /data
COPY homethread ./homethread
USER ht
EXPOSE 8080
# Ein Prozess: die Datenbank-Sperre gilt im Speicher, mehrere Worker würden sich in die Quere kommen
CMD ["uvicorn", "homethread.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-proxy-headers", "--no-server-header", "--timeout-keep-alive", "30"]
