# CS-412 Fuzzing Lab — runs INSIDE the Docker container.
# Targets: build, fuzz, fuzz-persistent, fuzz-qemu, plot, clean.

.PHONY: build fuzz fuzz-noasan fuzz-persistent fuzz-qemu plot clean

# Build four harness binaries:
#   /png_fuzz             -> instrumented (afl-clang-fast) + ASan, fork mode
#   /png_fuzz_noasan      -> instrumented (afl-clang-fast), NO sanitizer, fork mode
#   /png_fuzz_persistent  -> instrumented + ASan, persistent-mode harness
#   /png_fuzz_qemu        -> vanilla gcc build, links the non-instrumented libpng,
#                            used with afl-fuzz -Q (QEMU black-box mode)
build:
	afl-clang-fast /src/harness.c \
	    -I/libpng-1.2.51/install/include \
	    -L/libpng-1.2.51/install/lib \
	    -lpng12 -lz -lm \
	    -fsanitize=address -g -O1 \
	    -o /png_fuzz
	afl-clang-fast /src/harness.c \
	    -I/libpng-1.2.51/install_noasan/include \
	    -L/libpng-1.2.51/install_noasan/lib \
	    -lpng12 -lz -lm \
	    -g -O1 \
	    -o /png_fuzz_noasan
	afl-clang-fast /src/harness_persistent.c \
	    -I/libpng-1.2.51/install/include \
	    -L/libpng-1.2.51/install/lib \
	    -lpng12 -lz -lm \
	    -fsanitize=address -g -O1 \
	    -o /png_fuzz_persistent
	gcc /src/harness.c \
	    -I/libpng-1.2.51/install_vanilla/include \
	    -L/libpng-1.2.51/install_vanilla/lib \
	    -lpng12 -lz -lm \
	    -g -O1 \
	    -o /png_fuzz_qemu

# AFL_SKIP_CPUFREQ=1 is set on every fuzz target so the Makefile works on Docker
# Desktop / macOS / any host where /sys/devices/system/cpu/.../scaling_governor
# is not writable. Without it afl-fuzz refuses to start.

# Instrumented campaign. -x feeds the PNG dictionary shipped with AFL++.
fuzz:
	mkdir -p /findings
	AFL_SKIP_CPUFREQ=1 afl-fuzz -i /seeds -o /findings \
	    -x /AFLplusplus/dictionaries/png.dict \
	    -- /png_fuzz @@

# No-sanitizer + fork-mode campaign — Q8 baseline (config 1).
# -V 60 caps the run at 60s; we just need a stable execs/sec reading.
fuzz-noasan:
	mkdir -p /findings-noasan
	AFL_SKIP_CPUFREQ=1 afl-fuzz -i /seeds -o /findings-noasan \
	    -x /AFLplusplus/dictionaries/png.dict \
	    -V 60 \
	    -- /png_fuzz_noasan @@

# Persistent-mode campaign — used to demonstrate Q8's exec-speed gain over fork mode.
# Persistent harnesses read input from stdin / shared memory via __AFL_LOOP, NOT
# from a file path, so we drop the trailing `@@`.
# -V 60 caps the run at 60 seconds, enough to compare execs/sec against fork mode.
fuzz-persistent:
	mkdir -p /findings-persistent
	AFL_SKIP_CPUFREQ=1 afl-fuzz -i /seeds -o /findings-persistent \
	    -x /AFLplusplus/dictionaries/png.dict \
	    -V 60 \
	    -- /png_fuzz_persistent

# QEMU campaign — works on the non-instrumented binary via dynamic translation.
fuzz-qemu:
	mkdir -p /findings-qemu
	AFL_SKIP_CPUFREQ=1 afl-fuzz -Q -i /seeds -o /findings-qemu \
	    -x /AFLplusplus/dictionaries/png.dict \
	    -- /png_fuzz_qemu @@

# afl-plot needs the per-fuzzer dir (default/), not the top-level findings dir.
plot:
	afl-plot /findings/default/ /plot_output/
	afl-plot /findings-qemu/default/ /plot_output_qemu/

clean:
	rm -f /png_fuzz /png_fuzz_noasan /png_fuzz_persistent /png_fuzz_qemu
	rm -rf /findings /findings-noasan /findings-persistent /findings-qemu \
	       /plot_output /plot_output_qemu
