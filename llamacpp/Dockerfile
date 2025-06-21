# /zeno/llamacpp/Dockerfile
FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git build-essential cmake curl \
    libopenblas-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Create /zeno directory
RUN mkdir -p /zeno/llamacpp

# Clone llama.cpp into /zeno/llamacpp
WORKDIR /zeno/llamacpp
RUN git clone https://github.com/ggerganov/llama.cpp.git . \
    && mkdir -p build

# Build with CMake
RUN cmake -B build -DLLAMA_CUBLAS=ON -DLLAMA_BLAS=ON -DLLAMA_BLAS_VENDOR=OpenBLAS . && \
    cmake --build build --config Release -j$(nproc)

# Add entrypoint wrapper
COPY entrypoint.sh /zeno/llamacpp/entrypoint.sh
RUN chmod +x /zeno/llamacpp/entrypoint.sh

# Set working dir to models folder
WORKDIR /models
VOLUME ["/models"]

# Entrypoint
ENTRYPOINT ["/zeno/llamacpp/entrypoint.sh"]