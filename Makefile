PYTHON ?= python3
VENV ?= $(HOME)/.venvs/msxports
VPYTHON ?= $(VENV)/bin/python
BUILD ?= build
DISK1 ?= amiga/Robocop 2 (1991)(Ocean)[cr Melnok](Disk 1 of 2).adf
DISK2 ?= amiga/Robocop 2 (1991)(Ocean)[cr Melnok](Disk 2 of 2).adf
X := $(BUILD)/extracted

.PHONY: setup list extract pics ram seeds rea-asm sprites msx mock rom disasm test clean reference

setup:
	$(PYTHON) -m venv "$(VENV)"
	"$(VENV)/bin/pip" install -r requirements.txt

list:
	$(PYTHON) -I tools/rc2files.py list "$(DISK1)" "$(DISK2)"

extract:
	$(PYTHON) -I tools/rc2files.py extract "$(DISK1)" "$(DISK2)" "$(X)"

pics: extract
	$(PYTHON) -I tools/planar.py $(X)/files/DATAE_00.bin $(BUILD)/png/DATAE.png --width 320 --height 200 --planes 4 --offset 32 --pal-offset 0
	$(PYTHON) -I tools/planar.py $(X)/files/OAS_02.bin $(BUILD)/png/OAS.png --width 320 --height 200 --planes 4 --offset 32 --pal-offset 0
	$(PYTHON) -I tools/planar.py $(X)/files/TPIC_03.bin $(BUILD)/png/TPIC.png --width 320 --height 200 --planes 6 --offset 0x80 --pal-offset 0 --ham
	$(PYTHON) -I tools/planar.py $(X)/files/PICF_23.bin $(BUILD)/png/PICF.png --width 320 --height 256 --planes 6 --offset 0x80 --pal-offset 0 --ham
	for p in PIC1_08 PIC2_14 PIC3_12 PIC4_16 PIC5_19 PIC6_20 PIC7_21 PIC9_11; do \
		$(PYTHON) -I tools/planar.py $(X)/files/$$p.bin $(BUILD)/png/$$p.png --width 320 --height 176 --planes 6 --offset 0x80 --pal-offset 0 --ham; \
	done

ram: extract
	$(PYTHON) -I tools/ramimage.py $(X) $(BUILD)/ram/level1 RB1 MU1 DATAL1 SPERMA PERMA
	$(PYTHON) -I tools/ramimage.py $(X) $(BUILD)/ram/level2 RB1 MU1 DATAL2 MADEX SPERMA PERMA
	$(PYTHON) -I tools/ramimage.py $(X) $(BUILD)/ram/level3 RB1 MU1 DATAL3 PERMA

seeds: extract
	$(PYTHON) -I tools/ghidra_seeds.py $(X)/boot/main_8000.bin analysis/main_8000.sym analysis/ghidra_seeds.tsv

rea-asm: ram
	tools/rea_dump_asm.sh "$(CURDIR)/$(BUILD)/ram/level1_full.bin" 3

sprites: rea-asm
	$(PYTHON) -I tools/bobcatalog.py catalog
	$(PYTHON) -I tools/bobcatalog.py sheets
	$(PYTHON) -I tools/player.py $(BUILD)/sprites

$(BUILD)/ram/level1_full.bin:
	$(MAKE) ram

$(BUILD)/sprites/catalog.json:
	$(MAKE) sprites

# the BOB frames the original draws in level 1 (execution bench, long: ~20 minutes)
$(BUILD)/emu/cov_level1.json: $(BUILD)/ram/level1_full.bin
	$(VPYTHON) -I tools/amigacov.py --scenario level1 $@

msx: extract $(BUILD)/ram/level1_full.bin $(BUILD)/sprites/catalog.json $(BUILD)/emu/cov_level1.json
	$(VPYTHON) -I tools/msxsprites.py $(X)/boot/main_8000.bin $(X)/files/PERMA_05.bin $(X)/files/DATAL1_10.bin \
		--rows 51 --bobs $(BUILD)/sprites/catalog.json --drawn $(BUILD)/emu/cov_level1.json \
		--ram $(BUILD)/ram/level1_full.bin --level level1 --remove msx/level1_frames.json $(BUILD)/msx/robocop
	$(PYTHON) -I tools/msxconv.py level $(X)/files/DATAL1_10.bin --pal-file $(X)/boot/main_8000.bin \
		--pal-addr 0xfff6 --rows 51 --joint $(BUILD)/msx/robocop -o $(BUILD)/msx/level1
	$(PYTHON) -I tools/msxhud.py $(X)/files/PERMA_05.bin $(X)/boot/main_8000.bin $(BUILD)/msx/hud --black 4
	$(PYTHON) -I tools/msxhudrt.py $(X)/files/PERMA_05.bin $(X)/boot/main_8000.bin $(BUILD)/msx/hud_rt
	$(PYTHON) -I tools/player.py --inc $(BUILD)/msx/player.inc
	$(PYTHON) -I tools/msxtext.py $(BUILD)/ram/level1_full.bin $(BUILD)/msx/text.inc
	$(VPYTHON) -I tools/msxsound.py --out $(BUILD)/msx/sound.inc --budget 7680

rom: msx
	$(PYTHON) -I tools/mkrom.py $(BUILD)/msx/level1 $(BUILD)/msx/rc2.rom $(ROMOPTS)

mock: extract
	$(VPYTHON) -I tools/msxmock.py
	$(VPYTHON) -I tools/msxmock_or3.py
	$(VPYTHON) -I tools/msxmock_budget.py

disasm: extract
	$(VPYTHON) -I tools/m68kdis.py $(X)/boot/main_8000.bin --base 0x8000 --sym analysis/main_8000.sym \
		--a6 0xdff002 --scan-gaps -o $(BUILD)/dis/main_8000.s

test:
	$(PYTHON) -I -m unittest discover -s tests -v

# hardware reference for development (not part of the build; git-ignored: ASCII's text)
reference:
	git clone --depth 1 https://github.com/Konamiman/MSX2-Technical-Handbook.git reference/MSX2-Technical-Handbook

clean:
	rm -rf "$(BUILD)"
