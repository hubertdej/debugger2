CC := clang

OBJ := obj
INCLUDE := include
BIN := bin
SRC := src

# targets
INCLUDES := $(INCLUDE) $(OBJ)

SRCS := $(wildcard $(SRC)/*.cpp)
# BPF_SRCS := $(filter %.bpf.c, $(SRCS))

MAIN = main
# SRCS := $(filter-out $(BPF_SRCS),$(FULL_SRCS))
# OBJS := $(filter-out main.o,$(SRCS:.cpp=.o))
OBJS := $(patsubst $(SRC)/%.cpp,$(OBJ)/%.o,$(SRCS))

# tools
CLANG ?= clang
LLVM_STRIP ?= llvm-strip
BPFTOOL := bpftool
VMLINUX := $(OBJ)/vmlinux.h
ARCH := $(shell uname -m | sed 's/x86_64/x86/' | sed 's/aarch64/arm64/' | sed 's/ppc64le/powerpc/' | sed 's/mips.*/mips/')

# flags
IFLAGS := $(patsubst %,-I%,$(INCLUDES))
CXXFLAGS := -O3 -Wall -std=c++17
ALL_LDFLAGS := $(LDFLAGS) $(EXTRA_LDFLAGS)

# Get Clang's default includes on this system. We'll explicitly add these dirs
# to the includes list when compiling with `-target bpf` because otherwise some
# architecture-specific dirs will be "missing" on some architectures/distros -
# headers such as asm/types.h, asm/byteorder.h, asm/socket.h, asm/sockios.h,
# sys/cdefs.h etc. might be missing.
#
# Use '-idirafter': Don't interfere with include mechanics except where the
# build would have failed anyways.
CLANG_BPF_SYS_INCLUDES = $(shell $(CLANG) -v -E - </dev/null 2>&1 \
	| sed -n '/<...> search starts here:/,/End of search list./{ s| \(/.*\)|-idirafter \1|p }')

.PHONY: all
all: $(BIN)/$(MAIN)

.PHONY: clean
clean:
	rm -rf $(OBJ) $(BIN)

$(OBJ):
	mkdir -p $(OBJ)

$(BIN):
	mkdir -p $(BIN)

$(VMLINUX): | $(OBJ)
	$(BPFTOOL) btf dump file /sys/kernel/btf/vmlinux format c > $(VMLINUX)

# Build BPF code
$(OBJ)/tracer.bpf.o: $(SRC)/tracer.bpf.c $(INCLUDE)/constants.h $(VMLINUX) | $(OBJ)
	$(CLANG) -g -O3 -target bpf -D__TARGET_ARCH_$(ARCH) $(IFLAGS) $(CLANG_BPF_SYS_INCLUDES) -c $(filter %.c,$^) -o $@
	$(LLVM_STRIP) -g $@ # strip useless DWARF info

# Generate BPF skeletons
$(OBJ)/tracer.skel.h: $(OBJ)/tracer.bpf.o | $(OBJ)
	$(BPFTOOL) gen skeleton $< > $@


# Build user-space code
$(OBJ)/tracer_runner.o: $(OBJ)/tracer.skel.h
$(OBJ)/$(MAIN).o: $(OBJ)/tracer.skel.h

$(OBJS): $(OBJ)/%.o: $(SRC)/%.cpp $(INCLUDES) | $(OBJ)
	$(CC) $(CXXFLAGS) $(IFLAGS) -c $< -o $@

# Build application binary
$(BIN)/$(MAIN): $(OBJS) | $(BIN)
	$(CC) $(CXXFLAGS) $^ $(ALL_LDFLAGS) -lbpf -lelf -lz -o $@

# delete failed targets
.DELETE_ON_ERROR:

# keep intermediate (.skel.h, .bpf.o, etc) targets
.SECONDARY: