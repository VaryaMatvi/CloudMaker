FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-libvirt \
        qemu-utils cloud-image-utils genisoimage \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN python3 -m venv --system-site-packages /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

COPY main.py .

CMD ["/opt/venv/bin/uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]