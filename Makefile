# CS-412 Fuzzing Lab — runs INSIDE the Docker container.
# Targets: build, fuzz, fuzz-qemu, plot, clean.

.PHONY: build fuzz fuzz-qemu plot clean

# Build three harness binaries:
#   /png_fuzz             -> instrumented (afl-clang-fast + ASan) for normal afl-fuzz
#   /png_fuzz_persistent  -> same toolchain, persistent-mode harness (much faster execs/sec)
#   /png_fuzz_qemu        -> vanilla gcc build, links the non-instrumented libpng,
#                            used with afl-fuzz -Q (QEMU black-box mode)
build:
	afl-clang-fast /src/harness.c \
	    -I/libpng-1.2.56/install/include \
	    -L/libpng-1.2.56/install/lib \
	    -lpng12 -lz -lm \
	    -fsanitize=address -g -O1 \
	    -o /png_fuzz
	afl-clang-fast /src/harness_persistent.c \
	    -I/libpng-1.2.56/install/include \
	    -L/libpng-1.2.56/install/lib \
	    -lpng12 -lz -lm \
	    -fsanitize=address -g -O1 \
	    -o /png_fuzz_persistent
	gcc /src/harness.c \
	    -I/libpng-1.2.56/install_vanilla/include \
	    -L/libpng-1.2.56/install_vanilla/lib \
	    -lpng12 -lz -lm \
	    -g -O1 \
	    -o /png_fuzz_qemu

# Instrumented campaign. -x feeds the PNG dictionary shipped with AFL++ for smarter mutations.
fuzz:
	mkdir -p /findings
	afl-fuzz -i /seeds -o /findings \
	    -x /AFLplusplus/dictionaries/png.dict \
	    -- /png_fuzz @@

# QEMU campaign — works on the non-instrumented binary via dynamic translation.
fuzz-qemu:
	mkdir -p /findings-qemu
	afl-fuzz -Q -i /seeds -o /findings-qemu \
	    -x /AFLplusplus/dictionaries/png.dict \
	    -- /png_fuzz_qemu @@

# afl-plot needs the per-fuzzer dir (default/), not the top-level findings dir.
plot:
	afl-plot /findings/default/ /plot_output/
	afl-plot /findings-qemu/default/ /plot_output_qemu/

clean:
	rm -f /png_fuzz /png_fuzz_persistent /png_fuzz_qemu
	rm -rf /findings /findings-qemu /plot_output /plot_output_qemu
