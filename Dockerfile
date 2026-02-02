# Premium ComfyUI Nunchaku-Sage Template
# Maintainer: aijubied
FROM nvidia/cuda:12.6.1-cudnn-devel-ubuntu22.04

LABEL maintainer="aijubied"


# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Set shell to bash
SHELL ["/bin/bash", "-c"]

# Update and install essential packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common \
    curl \
    wget \
    git \
    vim \
    nginx \
    procps \
    unzip \
    openssh-server \
    libgl1 \
    libglib2.0-0 \
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    python3.12-distutils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set Python 3.12 as default python
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3.12 1

# Install Pip for Python 3.12
RUN curl -sS https://bootstrap.pypa.io/get-pip.py | python3.12

# Install NVM and Node.js (matching version v25.4.0 from env)
ENV NVM_DIR=/root/.nvm
RUN mkdir -p $NVM_DIR \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash \
    && . $NVM_DIR/nvm.sh \
    && nvm install v25.4.0 \
    && nvm alias default v25.4.0 \
    && nvm use default

# Add Node to PATH
ENV PATH=$NVM_DIR/versions/node/v25.4.0/bin:$PATH

# Install Filebrowser
RUN curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

# Install JupyterLab
RUN pip install jupyterlab

# Install essential media libraries
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsndfile1 \
    ffmpeg \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Clone ComfyUI to /Comfy
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /Comfy

# [PREMIUM] Pre-install ComfyUI Manager & Crystools & Extra Nodes
RUN cd /Comfy/custom_nodes && \
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git && \
    git clone https://github.com/crystian/ComfyUI-Crystools.git && \
    git clone https://github.com/jnxmx/ComfyUI_HuggingFace_Downloader.git && \
    git clone https://github.com/MoonGoblinDev/Civicomfy.git

# Copy local artifacts
COPY wheels /wheels
COPY scripts /scripts
COPY start.sh /start.sh

# Make start script executable
RUN chmod +x /start.sh

# Set up environment variables used in start.sh
ENV PYTHONWARNINGS="ignore"
ENV PIP_DISABLE_PIP_VERSION_CHECK="1"
ENV HF_HUB_DISABLE_TELEMETRY="1"

# Expose ports (ComfyUI, Jupyter, Filebrowser, AI Toolkit)
EXPOSE 8188 8888 8080 8675

# Set the entrypoint
CMD ["/start.sh"]
