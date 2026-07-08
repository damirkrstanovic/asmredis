AS      := nasm
ASFLAGS := -f elf64 -g -F dwarf -Iinclude
LD      := ld
LDFLAGS := -static -nostdlib
SRC     := $(wildcard src/*.asm)
OBJ     := $(SRC:src/%.asm=build/%.o)
BIN     := asmredis

all: $(BIN)

build/%.o: src/%.asm | build
	$(AS) $(ASFLAGS) $< -o $@

$(BIN): $(OBJ)
	$(LD) $(LDFLAGS) $(OBJ) -o $@

build:
	mkdir -p build

run: $(BIN)
	./$(BIN) 7777

test: $(BIN)
	bash tests/wire.sh

clean:
	rm -rf build $(BIN)

.PHONY: all run test clean
