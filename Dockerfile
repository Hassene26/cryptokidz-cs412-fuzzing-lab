# CS-412 Fuzzing Lab — libpng 1.2.56 + AFL++
# Reproducible environment. Build with: docker build -t cs412-fuzz .

FROM ubuntu:22.04

# Avoid tzdata / interactive prompts during apt installs
ENV DEBIAN_FRONTEND=noninteractive

# System deps:
#   build-essential                 -> gcc/g++/make for libpng vanilla build and AFL++ core
#   clang/llvm + llvm-14-dev/       -> LLVM headers required to build AFL++ llvm_mode
#     clang-14/lld-14/libclang-...     (afl-clang-fast); lld enables LTO mode
#   gcc-12-plugin-dev               -> headers required to build AFL++ gcc_plugin mode
#   python3-dev                     -> optional AFL++ python mutator support
#   wget/git                        -> fetch sources
#   libgd-dev/zlib1g-dev            -> libpng build deps (zlib is required)
#   gnuplot                         -> required by afl-plot
#   qemu-user                       -> required for afl-fuzz -Q
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    wget \
    git \
    clang \
    clang-14 \
    llvm \
    llvm-14 \
    llvm-14-dev \
    llvm-14-tools \
    libclang-14-dev \
    lld-14 \
    libstdc++-11-dev \
    gcc-11-plugin-dev \
    python3 \
    python3-dev \
    python3-pip \
    python3-setuptools \
    libgd-dev \
    zlib1g-dev \
    gnuplot \
    qemu-user \
    ninja-build \
    meson \
    pkg-config \
    libglib2.0-dev \
    libpixman-1-dev \
    bison \
    flex \
    ca-certificates \
    patch \
    && rm -rf /var/lib/apt/lists/*

# Build AFL++ from source.
# `make distrib` builds afl-clang-fast (LLVM mode), gcc_plugin mode, and the core tools,
# but NOT qemu_mode — that has its own build script. We invoke both, then `make install`.
RUN git clone https://github.com/AFLplusplus/AFLplusplus /AFLplusplus \
    && cd /AFLplusplus \
    && make distrib \
    && cd qemu_mode \
    && ./build_qemu_support.sh \
    && cd .. \
    && make install

# Fetch and unpack libpng 1.2.56
RUN wget -q https://download.sourceforge.net/libpng/libpng-1.2.56.tar.gz -O /tmp/libpng.tar.gz \
    && tar -xzf /tmp/libpng.tar.gz -C / \
    && rm /tmp/libpng.tar.gz

# Patches dir is staged in the image so the CRC patch (or any other) is available
COPY patches/ /patches/

# Disable PNG CRC checks so the fuzzer is not blocked by checksum mismatches on mutated inputs.
# Try the AFL++-provided patch first. If it fails (e.g. upstream patch drift), fall back to
# injecting `return 0;` at the top of png_crc_finish() in pngrutil.c via sed. The build then
# verifies the patch landed (greps for the inserted marker) and fails loudly if neither
# strategy worked, instead of silently building a CRC-checking libpng.
RUN cd /libpng-1.2.56 \
    && ( patch -p0 < /AFLplusplus/utils/libpng_no_checksum/libpng-nocrc.patch \
    && echo "[+] CRC patch applied via AFL++ patch" \
    ) \
    || ( echo "[!] AFL++ CRC patch failed, applying sed fallback" \
    && sed -i 's|^\(png_crc_finish\)\(.*\)$|\1\2\n   return 0; /* AFL++ CRC bypass */|' pngrutil.c \
    && grep -q "AFL++ CRC bypass" pngrutil.c \
    && echo "[+] CRC patch applied via sed fallback" \
    ) \
    || ( echo "[X] CRC patch FAILED — neither method worked, aborting build"; exit 1 )

# --- Instrumented build: used by afl-fuzz (no -Q). Static, ASan-enabled. ---
# --disable-shared so the harness statically links libpng and AFL coverage covers it.
RUN cd /libpng-1.2.56 \
    && CC=afl-clang-fast \
    CXX=afl-clang-fast++ \
    CFLAGS="-fsanitize=address -g -O1" \
    LDFLAGS="-fsanitize=address" \
    ./configure --disable-shared --prefix=/libpng-1.2.56/install \
    && make -j"$(nproc)" \
    && make install

# --- Vanilla build: used by afl-fuzz -Q (QEMU mode). No instrumentation, no sanitizers. ---
# distclean wipes the previous build artifacts so the two trees do not contaminate each other.
RUN cd /libpng-1.2.56 \
    && make distclean \
    && CC=gcc \
    CFLAGS="-g -O1" \
    ./configure --disable-shared --prefix=/libpng-1.2.56/install_vanilla \
    && make -j"$(nproc)" \
    && make install

# Harness sources (written by teammate) and seed corpus
COPY src/   /src/
COPY seeds/ /seeds/

WORKDIR /
