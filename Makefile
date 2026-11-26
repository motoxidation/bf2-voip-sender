alger: src/*.asm src/speex/*.asm src/speex/*.inc
	nasm -f elf64 -I src/ -o alger.o src/main.asm
	ld -o alger alger.o

clean:
	rm -f alger alger.o

.PHONY: clean
