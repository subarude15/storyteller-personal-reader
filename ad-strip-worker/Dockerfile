# Prefer Alpine + apk (Synology Docker: debian apt-get has hung in the past).
FROM python:3.12-alpine

RUN apk add --no-cache ffmpeg curl

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

ENV AD_STRIP_PORT=20129 \
    AD_STRIP_DATA=/data

RUN mkdir -p /data
VOLUME ["/data"]
EXPOSE 20129

CMD ["gunicorn", "-b", "0.0.0.0:20129", "-w", "1", "--threads", "4", "--timeout", "600", "app:app"]
