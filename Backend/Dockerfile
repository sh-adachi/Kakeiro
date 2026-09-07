FROM python:3.12-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt \
    && useradd --system --uid 10001 --create-home kakeiro \
    && mkdir /data && chown kakeiro:kakeiro /data
COPY kakeiro_backend ./kakeiro_backend
USER 10001:10001
EXPOSE 8787
CMD ["python", "-m", "kakeiro_backend"]
